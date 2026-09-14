#!/bin/bash
# 实验：PID namespace 当作「生命周期工具」时的三个失败面
#
# 这三个的答案都不是「报错」，而是*看起来成功了，代价在别处* ——
# 那种失败只有你自己盯着看才发现得了。
#
# 全程不需要 root（前两个实验需要非特权 user namespace 可用），跑完不留残留。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)

inner=""
cleanup() {
    [ -n "$inner" ] && kill -KILL "$inner" 2>/dev/null
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 判活要看 /proc/<pid>/stat 的第 3 个字段，不能用 kill -0 ——
# 僵尸进程对 kill -0 仍然返回成功，会把「已死」误报成「还活着」。
state_of() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo "已退出"; }
alive_note() {
    case "$1" in S|R|D|T|t) printf '（还活着）' ;; *) printf '' ;; esac
}

# ---------------------------------------------------- 失败面一：压根建不起来

out=$(unshare --pid --fork --mount-proc true 2>&1); rc=$?

# -------------------------------------------- 失败面二：身份被改掉了

uid1=$(unshare --user --pid --fork --mount-proc sh -c 'id -u' 2>/dev/null)
umap1=$(unshare --user --pid --fork --mount-proc cat /proc/self/uid_map 2>/dev/null)
uid2=$(unshare --user --map-current-user --pid --fork --mount-proc sh -c 'id -u' 2>/dev/null)
umap2=$(unshare --user --map-current-user --pid --fork --mount-proc cat /proc/self/uid_map 2>/dev/null |
        tr -s ' ' | sed 's/^ //; s/ $//')

# ------------------------------------------------- 失败面三：资源释放不干净

unshare --user --map-current-user --pid --fork sleep 300 &
wrapper=$!
sleep 0.5
disown
inner=$(pgrep -P "$wrapper" -x sleep | head -1)

kill -TERM "$wrapper" 2>/dev/null
sleep 0.5
term_w=$(state_of "$wrapper")
term_s=$(state_of "$inner")

kill -KILL "$wrapper" 2>/dev/null
sleep 0.5
kill_w=$(state_of "$wrapper")
kill_s=$(state_of "$inner")

kill -KILL "$inner" 2>/dev/null
sleep 0.5
inner=""
wait "$wrapper" 2>/dev/null

# --------------------------------------------------------- 挑出来的原始输出

[ -n "$umap1" ] && note1="uid_map: $umap1" || note1="uid_map 是空的"

cat <<EOF

  这个实验要回答：PID namespace 能不能当「父进程一死、孩子跟着走」的释放资源工具？

  三条实跑（都不需要 root）：
  unshare --pid --fork --mount-proc true   → ${out:-（没有任何输出）}（退出码 $rc）
  unshare --user --pid ... sh -c 'id -u'   → $uid1   宿主上的 uid 是 $(id -u)；$note1，65534 是内核的 overflow uid
  unshare --user --map-current-user ...    → $uid2   uid 映射对了（$umap2），可 D-Bus 认的是凭据上的那一个

  杀掉 wrapper，里面的 sleep 是它 fork 出来的：
  kill -TERM wrapper   → wrapper 状态 $term_w，sleep 状态 $term_s$(alive_note "$term_s")
  kill -KILL wrapper   → wrapper 状态 $kill_w，sleep 状态 $kill_s$(alive_note "$kill_s")

  三个失败面：一、非特权用户单建 PID namespace 建不起来；二、先建 user namespace，uid 变成 65534，
  按 uid 认人的机制全部拒绝你；三、建起来了也释放不了资源 —— namespace 不是一棵能整棵砍掉的树，
  里面的 pid 1 死了，内核不会顺手把同 namespace 的其他人也带走。

  这用在哪：错的工具当场就报错，你会立刻换一个；它要是「看起来成功、代价在别处」，
  你就会一直在它上面打补丁 —— 常驻进程的生命周期正是这样被拖住的。
EOF
