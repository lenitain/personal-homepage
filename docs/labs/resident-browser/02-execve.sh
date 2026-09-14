#!/bin/bash
# 实验：execve 换掉内容，但不换进程
#
# 承接 01 —— 那里复制出来的那份，内容跟原来一模一样，还是 shell。
# 这一份看两步里的第二步：怎么把复制品换成你真正想跑的程序。
#
# 形态说明：这个实验要回答的就是「pid 变不变」—— 所以跑完给同一 pid 的前后两行。
#
# 关键细节：卡住这一下必须由外面控制（这里用一根 fifo），才分得出 exec 前后两个时刻。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「第二步：换内容」。
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

cat >execstep.c <<'EOF'
/* 报到，然后卡在 stdin 上等你放行；拿到一行就 execve 换成 /bin/sh。
 *
 * 「名字」是从 /proc/<pid>/comm 读的 —— 那是*内核眼里*这个进程叫什么，
 * 不是它自己打印的字符串。execve 换掉的正是这个。
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void report(const char *tag)
{
    char name[64] = "?";
    FILE *f = fopen("/proc/self/comm", "r");
    if (f) {
        if (fgets(name, sizeof name, f)) name[strcspn(name, "\n")] = 0;
        fclose(f);
    }
    printf("  [%s] pid = %d   内核眼里的名字 = %s\n", tag, getpid(), name);
    fflush(stdout);
}

int main(void)
{
    char line[64];

    report("换之前");
    if (!fgets(line, sizeof line, stdin)) return 0;   /* 等人放行 */
    report("还是它");

    /* 换成 /bin/sh，让它报出自己的 pid —— /proc/$$ 里的 $$ 是 sh 自己 */
    execl("/bin/sh", "sh", "-c",
          "echo \"  [换之后] pid = $$   内核眼里的名字 = $(cat /proc/$$/comm)\"",
          (char *)0);
    perror("execl");
    return 127;
}
EOF

gcc -O2 -o execstep execstep.c

mkfifo gate
./execstep >trace.txt 2>&1 <gate &
pids+=("$!")
exec 3>gate          # 把写端打开，子进程才过得了 open，不然两边一起卡住

for _ in $(seq 1 100); do [[ -s trace.txt ]] && break; sleep 0.1; done
echo go >&3
for _ in $(seq 1 100); do grep -q '换之后' trace.txt && break; sleep 0.1; done
exec 3>&-

pid=$(grep -o 'pid = [0-9]*' trace.txt | head -1 | grep -o '[0-9]*')
after_pid=$(grep '换之后' trace.txt | grep -o 'pid = [0-9]*' | grep -o '[0-9]*')
before_name=$(grep '换之前' trace.txt | sed 's/.*名字 = //')
after_name=$(grep '换之后' trace.txt | sed 's/.*名字 = //')

printf '\n  这个实验要回答：execve 换了进程里装的东西，pid 会变吗？\n\n'
printf '  同一个进程，execve 前后各报一次自己（名字读自 /proc/<pid>/comm）：\n\n'
printf '    时刻       pid       内核眼里的名字\n'
printf '    换之前     %-8s  %s\n' "$pid" "$before_name"
printf '    换之后     %-8s  %s\n' "$after_pid" "$after_name"
cat <<'EOF'

  *两个 pid 是同一个数*：execve 不产生新进程，只是把同一个进程里装的东西换掉 ——
  换的是「里面装的是哪个程序」，不是「这是哪个进程」。

  用在哪：启动到这里才走完两步，而重头在第二步 —— 一个什么都不干的小程序启动也要
  几百微秒，绝大部分是 fork + execve 本身（第 4 章的 07 量过这笔账）。
EOF
