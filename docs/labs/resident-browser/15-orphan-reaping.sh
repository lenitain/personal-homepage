#!/bin/bash
# 实验：父进程退出之后，子进程归谁？
#
# 这是「谁负责生命周期」那个决定的前提。没有它，「别自己写监督进程」只是一句主张 ——
# 因为使用者脑子里的模型是「关掉终端/关掉窗口，程序就没了」，
# 而这个模型在「让一个进程活得比启动它的东西更久」这件事上不成立。
#
# 看什么：
#
#   一、一个后台进程的父进程退出之后，它没有被杀掉，也没有变成没人管的孤儿：
#      内核把它交给了**离它最近的 subreaper** —— 你的会话里通常是 user manager，
#      否则就是 pid 1。这一步是内核做的，不需要你安排。
#   二、被接管 ≠ 被收拾：内核只负责「谁当它爹」，不负责「它留下的东西谁清」。
#      这一条把第 2 章的问题立起来。
#   三、`nohup` / `setsid` 不是「让进程活下来」的开关，它们只是把终端和会话
#      那几条线剪掉，好让 SIGHUP 打不到它。
#
# 全程不需要 root，跑完不留残留。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 判活看状态字段，不看 kill -0 —— 僵尸进程对 kill -0 仍然返回成功。
state_of() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo "已退出"; }
ppid_of()  { awk '{print $4}' "/proc/$1/stat" 2>/dev/null || echo "-"; }
alive_note() { case "$1" in S|R|D|T|t) printf '（还活着）' ;; *) printf '' ;; esac; }

printf '\n  这个实验要回答：让一个进程活得比启动它的东西更久，会出什么事？\n\n'

# ------------------------------------------------ 一：父进程退出，孩子归谁

# 外层子 shell 起一个 sleep 就退出 —— 于是 sleep 的父进程立刻消失。
( sleep 300 & echo "$!" >"$WORK/orphan.pid" ) &
wait $! 2>/dev/null
orphan=$(cat "$WORK/orphan.pid")
pids+=("$orphan")
sleep 0.4

o_state=$(state_of "$orphan")
o_ppid=$(ppid_of "$orphan")
reaper_name=$(cat "/proc/$o_ppid/comm" 2>/dev/null || echo '?')
reaper_args=$(tr '\0' ' ' <"/proc/$o_ppid/cmdline" 2>/dev/null | cut -c1-60)
self_pid=$$

printf '  一、父进程立刻退出之后，那个 sleep 怎么样了\n'
printf '    本脚本 pid %s 起了个子 shell，子 shell 起了 sleep（pid %s）就退出了。\n' "$self_pid" "$orphan"
printf '    sleep 状态 %s%s，现在的父进程是 pid %s（%s）\n' \
    "$o_state" "$(alive_note "$o_state")" "$o_ppid" "$reaper_name"
[ -n "$reaper_args" ] && printf '      pid %s 是：%s\n' "$o_ppid" "$reaper_args"
printf '    它没有死 —— 内核把它交给了*离它最近的 subreaper*。\n'
printf '    在你的会话里通常就是 user manager（systemd --user），否则是 pid 1。\n\n'

# ------------------------------------------------ 二：被接管 ≠ 被收拾

printf '  二、接管不等于收拾\n'
printf '    内核做的只有一件事：\n'
printf '      「原来那个父进程没了，从这个进程往上找，找到第一个 subreaper，换它当爹」\n'
printf '    它不做的事：那个 sleep 活着的时候占着的东西、留下的文件、开着的端口，\n'
printf '    没有任何一处会因为「它被 pid %s 接管了」而被清理。\n' "$o_ppid"
printf '    所以「有人管着它」和「它死了之后有人收拾」是两件事 ——\n'
printf '    第 2 章的 11 量的是后一件：光有 cgroup 不够，还得有人指定谁是主进程。\n\n'

# ------------------------------------------------ 三：几条文具

printf '  三、nohup / setsid 到底做了什么\n'
( setsid sleep 300 & echo "$!" >"$WORK/setsid.pid" ) &
wait $! 2>/dev/null
sid_proc=$(cat "$WORK/setsid.pid")
pids+=("$sid_proc")
sleep 0.3
printf '    setsid 起的那个（pid %s）：\n' "$sid_proc"
ps -o pid,ppid,sid,pgid,comm -p "$sid_proc" 2>/dev/null | sed 's/^/      /'
printf '    看 sid 那一列：它自己成了一个会话首进程，于是终端发 SIGHUP 时\n'
printf '    打不到它 —— 这就是 nohup/setsid 的全部作用，不是什么保命开关。\n'
printf '    （你的 shell 里如果有 job control，普通后台进程也在自己的进程组里，\n'
printf '     但仍在同一个会话中，所以终端一断它还是会收到 SIGHUP。）\n\n'

# ------------------------------------------------ 用在哪

cat <<'EOF'
  用在哪：这是「常驻 qutebrowser」的物质基础 ——
  一个进程可以比启动它的终端、比你的登录会话活得久。
  于是接下来的问题不是「怎么让它活着」（内核会办），而是「它的死该由谁负责」：
  被 pid 1 接管只是换了个爹，动手收走整棵树是另一件事（11 量的是这件事）。
EOF
