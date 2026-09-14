#!/bin/bash
# 实验：fork 把一个进程变成两个
#
# 承接序的开头 —— 那里问「qutebrowser 那一秒多该从哪儿查起」，
# 入口是「跑一个程序在内核眼里是什么」。这一份看两步里的第一步：复制。
#
# 形态说明：这个实验要回答的就是「一个变成几个」—— 所以跑完给一张进程表。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「第一步：复制」。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
pids=()

cleanup() {
    (( ${#pids[@]} )) && kill "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cd "$WORK"

cat >forkhold.c <<'EOF'
/* fork 一次，父子两边各报自己是谁，然后都停在那儿不退出。
   父进程从 fork 拿到子进程的 pid，子进程拿到 0 —— 这就是它们唯一的区别。 */
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>

int main(void)
{
    printf("fork 之前：屏幕前只有我一个进程，pid = %d\n", getpid());
    fflush(stdout);   /* 先刷出去 —— 否则这段缓冲会被复制一份，父子各打印一遍 */

    pid_t me = getpid();
    pid_t pid = fork();          /* 这一行之后，代码在两个进程里各往下走一遍 */

    if (pid == 0) {
        /* 父进程一死，内核就把我也收走。不然外面 kill 掉父进程之后，
           我还在这儿赖着 —— 实验收不了尾。 */
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() != me) _exit(0);   /* 父进程已经先走了，别赖着 */
        printf("  [子进程] 我是复制出来的那一份，pid = %d\n", getpid());
    } else {
        printf("  [父进程] 我还在，pid = %d；fork 交给我的那个 pid 是 %d\n",
               getpid(), pid);
    }
    fflush(stdout);

    sleep(1000000);   /* 停在这儿，等你在进程列表里看够了再收 */
    return 0;
}
EOF

gcc -O2 -o forkhold forkhold.c

./forkhold >out.txt 2>&1 &
pids+=("$!")
for _ in $(seq 1 100); do grep -q '子进程' out.txt 2>/dev/null && break; sleep 0.1; done

parent=$(head -1 out.txt | grep -o '[0-9]*$')
kid=$(grep '子进程' out.txt | grep -o '[0-9]*$')
read -r parent_pid parent_ppid < <(ps -o pid=,ppid= -p "$parent")
read -r kid_pid kid_ppid < <(ps -o pid=,ppid= -p "$kid")

printf '\n  这个实验要回答：fork 一次，一个进程变成了几个？\n\n'
printf '  程序 fork 一次之后就不走了；同一时刻内核报的进程列表：\n\n'
printf '    PID       PPID     COMMAND\n'
printf '    %-8s  %-7s  %-9s  ← 父进程\n' "$parent_pid" "$parent_ppid" forkhold
printf '    %-8s  %-7s  %-9s  ← 子进程\n' "$kid_pid" "$kid_ppid" forkhold
cat <<'EOF'

  fork 只调用了一次，它下面的代码却*两个进程各跑了一遍* —— 唯一的区别是返回值：
  子进程拿到 0，父进程拿到子进程的 pid（所以上面子进程的 PPID 正是父进程的 PID）。

  用在哪：qutebrowser 的启动正是「fork 复制 + execve 换内容」两步，而复制几乎没有开销
  —— 它复制的是一堆*约定*，不是内存（06 会量）。那一秒多花在下一步（02）。
EOF
