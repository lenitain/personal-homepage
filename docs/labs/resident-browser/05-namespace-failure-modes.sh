#!/bin/bash
# 实验 1 / 2 / 5：PID namespace 当作「生命周期工具」时的三个失败面
#
# 输出刻意做成 shell 会话记录的样子 —— 文章里贴的就是它跑出来的东西，
# 所以这里不美化、不摘要，命令和输出一一对应。
#
# 全程不需要 root，跑完不留残留。
set -uo pipefail

hr() { printf '\n──── %s ────\n\n' "$1"; }

# 判活要看 /proc/<pid>/stat 的第 3 个字段，不能用 kill -0 ——
# 僵尸进程对 kill -0 仍然返回成功，会把「已死」误报成「还活着」。
state_of() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo "已退出"; }

hr "实验 1：非特权用户能单独创建 PID namespace 吗"

printf '$ unshare --pid --fork --mount-proc true\n'
unshare --pid --fork --mount-proc true
printf '退出码 %s\n' "$?"

hr "实验 2：先建 user namespace，uid 变成什么"

printf '$ unshare --user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"\n'
unshare --user --pid --fork --mount-proc sh -c 'id -u; echo "(↑ getuid，↓ uid_map)"; cat /proc/self/uid_map'
printf '宿主上的 uid 是 %s。65534 是内核的 overflow uid，没有映射时拿它顶。\n' "$(id -u)"

printf '\n$ unshare --user --map-current-user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"\n'
unshare --user --map-current-user --pid --fork --mount-proc sh -c 'id -u; cat /proc/self/uid_map'

hr "实验 5：杀掉 unshare 这个 wrapper，里面的进程跟着走吗"

unshare --user --map-current-user --pid --fork sleep 300 &
wrapper=$!
sleep 0.5
disown
inner=$(pgrep -P "$wrapper" -x sleep | head -1)

printf 'wrapper pid = %s\n' "$wrapper"
printf 'namespace 里的 sleep pid = %s\n\n' "$inner"

printf '$ kill -TERM %s\n' "$wrapper"
kill -TERM "$wrapper" 2>/dev/null
sleep 0.5
printf '  wrapper 状态 = %s\n' "$(state_of "$wrapper")"
printf '  sleep   状态 = %s\n' "$(state_of "$inner")"

printf '\n$ kill -KILL %s\n' "$wrapper"
kill -KILL "$wrapper" 2>/dev/null
sleep 0.5
printf '  wrapper 状态 = %s\n' "$(state_of "$wrapper")"
printf '  sleep   状态 = %s\n' "$(state_of "$inner")"

printf '\n$ kill -KILL %s   # 收拾干净\n' "$inner"
kill -KILL "$inner" 2>/dev/null
sleep 0.5
printf '  sleep   状态 = %s\n' "$(state_of "$inner")"
wait "$wrapper" 2>/dev/null
