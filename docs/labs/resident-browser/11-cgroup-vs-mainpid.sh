#!/bin/bash
# 实验：为什么「有 cgroup」还不够，必须有 MainPID 跟踪
#
# 承接 10 —— namespace 当释放资源工具的三个代表面全否了：建不起来、改掉你的身份、
# 连 wrapper 死了都带不走里面的进程。释放资源这件事得换人做，换成 pid 1。
#
# 这个实验要问的是：pid 1 的两种用法（scope / service）差在哪一件事上。
# 三种启动方式跑同一个形状的进程树（一个「主进程」+ 一个它拉起来的子进程），
# 然后 SIGKILL 掉主进程，看子进程活不活得下来：
#
#   A  裸 setsid            —— 没有 cgroup
#   B  systemd 临时 scope   —— 有 cgroup，但没有 MainPID
#   C  systemd 临时 service —— 有 cgroup，也有 MainPID
#
# 三档里有两档的「失败」长得很像成功，所以每一档都要单独看子进程的存活状态。
#
# 全程用 --user，不碰系统单元；跑完清理。
#
# 坑（值得记着）：payload 必须放进脚本文件，不能用 `sh -c '<payload>'`。
# systemd 会对 ExecStart 做 `$` 展开，而 `$$` 在那里是「转义成字面美元符」的意思
# —— 于是 `echo $$` 到了进程里变成 `echo $`，主进程 pid 根本拿不到，
# B、C 两档会静默地什么都没杀，实验看起来「通过」了其实完全无效。
# 脚本文件里的 `$$` 不经过 systemd，才是安全的。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

UNIT_SCOPE="lab-scope-$$"
UNIT_SERVICE="lab-service-$$"

WORK=$(mktemp -d)
PAYLOAD="$WORK/payload.sh"
cat >"$PAYLOAD" <<'PAYLOAD_EOF'
#!/bin/sh
# 复刻一棵最小进程树：主进程拉起一个后台子进程，然后等它
sleep 300 &
echo "$! $$" > "$1"
wait
PAYLOAD_EOF
chmod +x "$PAYLOAD"

# 判活看 /proc/<pid>/stat 的状态字段；Z = 僵尸（已死，只是还没被回收）
alive() {
    local s
    s=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null) || { echo "已退出"; return; }
    case "$s" in Z) echo "僵尸（已死）" ;; *) echo "存活（$s）" ;; esac
}

cleanup() {
    systemctl --user stop "$UNIT_SCOPE.scope" "$UNIT_SERVICE.service" >/dev/null 2>&1
    systemctl --user reset-failed "$UNIT_SCOPE.scope" "$UNIT_SERVICE.service" >/dev/null 2>&1
}
trap 'cleanup; rm -rf "$WORK"' EXIT

# ------------------------------------------------ 1. MainPID 是谁指定的
#
# 一个单元名对应两行：cgroup 在哪，主进程是谁。这两行就是这一节的答案。
unit_field() { systemctl --user show "$1" -p "$2" --value 2>/dev/null; }

systemd-run --user --scope --unit="$UNIT_SCOPE" sleep 60 >/dev/null 2>&1 &
disown
sleep 1
scope_cg=$(unit_field "$UNIT_SCOPE.scope" ControlGroup)
scope_mp=$(unit_field "$UNIT_SCOPE.scope" MainPID)

systemd-run --user --unit="$UNIT_SERVICE" sleep 60 >/dev/null 2>&1
sleep 1
svc_mp=$(unit_field "$UNIT_SERVICE.service" MainPID)

cleanup
sleep 0.5

# --------------------------------------- 2. 三种启动方式，谁收得干净

for mode in A B C; do
    record="$WORK/record-$mode"
    : >"$record"

    case "$mode" in
    A)
        setsid "$PAYLOAD" "$record" >/dev/null 2>&1 &
        disown
        ;;
    B)
        systemd-run --user --scope --unit="$UNIT_SCOPE" "$PAYLOAD" "$record" >/dev/null 2>&1 &
        disown
        ;;
    C)
        systemd-run --user --unit="$UNIT_SERVICE" "$PAYLOAD" "$record" >/dev/null 2>&1
        ;;
    esac

    # payload 把「子 pid 主 pid」写进文件
    sleep 1.5
    read -r child main <"$record" 2>/dev/null || { child=""; main=""; }

    result="没拿到主进程 pid，这一档没测成"
    if [[ -n "${main:-}" ]]; then
        kill -KILL "$main" 2>/dev/null
        sleep 0.3
        result="$([[ -n "${child:-}" ]] && alive "$child" || echo '子进程 pid 没拿到')"
    fi
    case "$mode" in
    A) A_RES="$result" ;;
    B) B_RES="$result" ;;
    C) C_RES="$result" ;;
    esac

    [[ -n "${child:-}" ]] && kill -KILL "$child" 2>/dev/null
    cleanup
done

# 两边的 ControlGroup 都落在同一个父目录下，共同前缀折掉，只留能看出「建出来了」的部分
short_cg() { printf '%s' "${1##*/app.slice/}"; }

cat <<EOF

  这个实验要回答：拿 pid 1 释放资源，光有 cgroup 够不够？

  同一个命令，两种 systemd 用法，各建出一个 cgroup：
    --scope   $(short_cg "$scope_cg")   MainPID ${scope_mp:-（空）}
    --unit    $UNIT_SERVICE.service   MainPID $svc_mp

  同一棵进程树（主进程 + 一个它拉起的子进程），SIGKILL 掉主进程之后：
    A  裸 setsid            没有 cgroup              子进程 $A_RES
    B  systemd 临时 scope   有 cgroup，MainPID 空    子进程 $B_RES
    C  systemd 临时 service 有 cgroup，MainPID 有    子进程 $C_RES

  最容易看走眼的是 B：systemd-cgls 看过去和 C 一模一样，可它不负责释放资源。
  「有个容器把它装着」和「有人知道谁是主进程」是两件事，保证来自后者。

  这用在哪：常驻 qutebrowser 的前提到此定下来 —— 那一秒多只付一次，靠的就是它一直活着，
  而它比启动它的东西活得久之后，谁负责收走它由 pid 1 盯着，
  不依赖浏览器讲道理，也不依赖启动脚本把信号转发对。
EOF
