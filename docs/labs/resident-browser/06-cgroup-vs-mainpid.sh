#!/bin/bash
# 实验 6 / 7：为什么「有 cgroup」还不够，必须有 MainPID 跟踪
#
# 三种启动方式跑同一个形状的进程树（一个「主进程」+ 一个它拉起来的子进程），
# 然后 SIGKILL 掉主进程，看子进程活不活得下来。
#
# 差别只有一个：这个 cgroup 有没有把某个进程指定为「主进程」。
#
#   A  裸 setsid            —— 没有 cgroup
#   B  systemd 临时 scope   —— 有 cgroup，但没有 MainPID
#   C  systemd 临时 service —— 有 cgroup，也有 MainPID
#
# 全程用 --user，不碰系统单元；跑完清理。
#
# 坑（值得记着）：payload 必须放进脚本文件，不能用 `sh -c '<payload>'`。
# systemd 会对 ExecStart 做 `$` 展开，而 `$$` 在那里是「转义成字面美元符」的意思
# —— 于是 `echo $$` 到了进程里变成 `echo $`，主进程 pid 根本拿不到，
# B、C 两档会静默地什么都没杀，实验看起来「通过」了其实完全无效。
# 脚本文件里的 `$$` 不经过 systemd，才是安全的。
set -uo pipefail

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

hr() { printf '\n──── %s ────\n\n' "$1"; }

hr "实验 6：scope 和 service 的 MainPID 有什么不一样"

printf '$ systemd-run --user --scope --unit=%s sleep 60 &\n' "$UNIT_SCOPE"
systemd-run --user --scope --unit="$UNIT_SCOPE" sleep 60 >/dev/null 2>&1 &
disown
printf '$ systemd-run --user --unit=%s sleep 60\n' "$UNIT_SERVICE"
systemd-run --user --unit="$UNIT_SERVICE" sleep 60 >/dev/null 2>&1
sleep 1

printf '\n$ systemctl --user show %s.scope -p MainPID\n' "$UNIT_SCOPE"
out=$(systemctl --user show "$UNIT_SCOPE.scope" -p MainPID)
printf '%s\n' "${out:-MainPID=（空）}"

printf '$ systemctl --user show %s.service -p MainPID\n' "$UNIT_SERVICE"
systemctl --user show "$UNIT_SERVICE.service" -p MainPID

cleanup
sleep 0.5

hr "实验 7：SIGKILL 掉主进程，子进程谁活下来"

for mode in A B C; do
    record="$WORK/record-$mode"
    : >"$record"

    case "$mode" in
    A)
        printf '【A】裸 setsid —— 没有 cgroup\n'
        printf '$ setsid payload.sh %s &\n' "$record"
        setsid "$PAYLOAD" "$record" >/dev/null 2>&1 &
        disown
        ;;
    B)
        printf '【B】systemd 临时 scope —— 有 cgroup，没有 MainPID\n'
        printf '$ systemd-run --user --scope --unit=%s payload.sh %s &\n' "$UNIT_SCOPE" "$record"
        systemd-run --user --scope --unit="$UNIT_SCOPE" "$PAYLOAD" "$record" >/dev/null 2>&1 &
        disown
        ;;
    C)
        printf '【C】systemd 临时 service —— 有 cgroup，也有 MainPID\n'
        printf '$ systemd-run --user --unit=%s payload.sh %s\n' "$UNIT_SERVICE" "$record"
        systemd-run --user --unit="$UNIT_SERVICE" "$PAYLOAD" "$record" >/dev/null 2>&1
        ;;
    esac

    # payload 把「子 pid 主 pid」写进文件
    sleep 1.5
    read -r child main <"$record" 2>/dev/null || { child=""; main=""; }
    printf '  主进程 pid = %s，子进程 pid = %s\n' "${main:-?}" "${child:-?}"

    if [[ -n "${main:-}" ]]; then
        printf '  $ kill -KILL %s\n' "$main"
        kill -KILL "$main" 2>/dev/null
    fi
    sleep 1.5

    printf '  => 子进程 %s：%s\n' "${child:-?}" "$([[ -n "${child:-}" ]] && alive "$child" || echo '?')"

    [[ -n "${child:-}" ]] && kill -KILL "$child" 2>/dev/null
    cleanup
    printf '\n'
done
