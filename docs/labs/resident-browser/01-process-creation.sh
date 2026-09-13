#!/bin/bash
# 演示：Linux 是怎么弄出一个新进程的
#
# 这是整门课的起点，所以从最小的事实开始：
#   跑一个程序，在内核看来是两步 —— 先复制（fork），再换内容（execve）。
#
# 读者可能从没听说过 fork，更不知道为什么要有两步。这一份把它跑出来，
# 并且用「你已经用过一百次的东西」解释第二步之前那一步有什么用。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

hr() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# ------------------------------------------------ 1. fork：复制一份自己

hr "1. fork：把当前进程原样复制一份"

cat >forkonly.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    printf("fork 之前：我是一个进程，pid = %d\n", getpid());
    fflush(stdout);   /* 先把缓冲刷出去 —— 否则这段缓冲会被复制一份，
                         父进程再刷一次，那行就打印两遍（初学者常被这个绕住） */

    pid_t pid = fork();          /* 从这一行之后，代码在两个进程里同时往下走 */

    if (pid == 0) {
        printf("  [子进程] 我是复制出来的那一份，pid = %d，我的父进程是 %d\n",
               getpid(), getppid());
    } else {
        printf("  [父进程] 我还在，pid = %d，我复制出来的那个是 %d\n",
               getpid(), pid);
        wait(NULL);
    }
    return 0;
}
EOF

gcc -O2 -o forkonly forkonly.c
echo '$ ./forkonly'
./forkonly

printf '\n  注意三件事：\n'
printf '    · fork 只调用了一次，但 printf 下面的代码**两个进程各跑了一遍**\n'
printf '    · 两个进程的 pid 不同 —— 这是它们唯一的区别\n'
printf '    · fork 的返回值就是用来区分的：子进程拿到 0，父进程拿到子进程的 pid\n'

# ------------------------------------- 2. execve：换个内容，不换进程

hr "2. execve：把这份复制品的内容换掉，但进程还是同一个"

cat >execafter.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    printf("exec 之前：pid = %d\n", getpid());
    fflush(stdout);

    pid_t pid = fork();
    if (pid == 0) {
        /* 子进程：把「我自己」换成 /bin/echo */
        execl("/bin/echo", "echo", "  [子进程] 这是 /bin/echo 在说话", (char *)0);
        _exit(127);   /* execl 成功的话不会走到这里 */
    }

    printf("父进程等子进程，它的 pid 是 %d\n", pid);
    wait(NULL);
    return 0;
}
EOF

gcc -O2 -o execafter execafter.c
echo '$ ./execafter'
./execafter

printf '\n  让它自己说话，证明 pid 没变：\n\n'

cat >pidcheck.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) {
        char buf[32];
        snprintf(buf, sizeof buf, "%d", getpid());
        setenv("MY_PID", buf, 1);
        /* 换成 /bin/sh，让它把继承来的环境变量打出来 */
        execl("/bin/sh", "sh", "-c", "echo \"  [sh 说] 我是 pid $MY_PID\"", (char *)0);
        _exit(127);
    }
    printf("  [父进程] 我 fork 出来的 pid = %d\n", pid);
    wait(NULL);
    return 0;
}
EOF

gcc -O2 -o pidcheck pidcheck.c
echo '$ ./pidcheck'
./pidcheck

printf '\n  两个 pid 一样 —— 这就是关键：\n'
printf '    execve **不产生新进程**，它只是把同一个进程的内容换掉\n'
printf '    pid 不变，进程在系统里的身份也不变，换的只是「里面装的是什么程序」\n'

# --------------------------------- 3. 为什么分成两步：shell 就是这么用的

hr "3. 为什么非要分两步：因为中间那一步有用"

cat >redir.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

int main(void) {
    pid_t pid = fork();
    if (pid == 0) {
        /* exec 之前，先动自己的文件描述符表 —— 这只会影响我自己 */
        int fd = open("out.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        dup2(fd, STDOUT_FILENO);   /* 让「标准输出」指向那个文件 */
        close(fd);
        execl("/bin/echo", "echo", "这行字会进文件，不会出现在屏幕上", (char *)0);
        _exit(127);
    }
    wait(NULL);
    printf("  （屏幕上什么都没有，对吧？）\n");
    printf("  文件里现在写的是：");
    fflush(stdout);
    execl("/bin/cat", "cat", "out.txt", (char *)0);
    return 0;
}
EOF

gcc -O2 -o redir redir.c
echo '$ ./redir'
./redir

printf '\n  上面这个程序重写了 shell 每天都在做的事：\n'
printf '    你敲  echo hello > out.txt\n'
printf '    shell 并不是「让 echo 去写文件」—— echo 根本不知道有文件这回事\n'
printf '    实际是：shell fork 出自己 → 子进程把标准输出改成那个文件 → 再 exec echo\n'
printf '\n  管道（|）也是同一个套路，只是把「指向文件」换成「指向另一个进程」。\n'
printf '  —— 所以 fork 和 exec 分成两步不是历史的偶然，是**故意留出中间那一步**。\n'

# --------------------------------------------- 4. 你刚才其实已经用过它

hr "4. 回头看：你按下回车时发生了什么"

cat <<'EOF'
  你在 shell 里敲下 qutebrowser 然后回车。shell 做的事是：

    fork()    复制一个自己出来
    execve()  把复制品的内容换成 qutebrowser

  所以「启动一个程序」在 Linux 上不是一个动作，是两个。
  接下来要看的就是第二步到底要花多少工夫 ——
  execve 到底做了什么，为什么换个程序会有快有慢。

  （下一步：02-elf-loading.sh）
EOF
