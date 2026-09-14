#!/bin/bash
# 实验：fork 和 exec 之间那一步，就是 shell 重定向的实现
#
# 承接 02 —— 那里看到 execve 会把进程里装的东西整个换掉。
# 这一份看「先复制、再换掉」中间空出来的那一步：它有用吗？
#
# 形态说明：同一句 echo 跑两次，只有一处不同 —— 第二次在 exec 之前把标准输出
# 改成了文件。跑完把两次的去向并排列出来。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程是怎么启动的」。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat >redir.c <<'EOF'
/* 用法: redir <plain|duped>
 *
 * plain   直接 exec echo —— 话说到屏幕上
 * duped   先 fork，让子进程把自己的标准输出改成 out.txt，再 exec echo
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "duped")) {
        pid_t pid = fork();
        if (pid == 0) {
            /* exec 之前，先动自己的文件描述符表 —— 这只会影响我自己 */
            int fd = open("out.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            dup2(fd, STDOUT_FILENO);   /* 让「标准输出」指向那个文件 */
            close(fd);
            execl("/bin/echo", "echo", "这句话进了文件，没上屏幕", (char *)0);
            _exit(127);
        }
        wait(NULL);
        return 0;
    }
    execl("/bin/echo", "echo", "这句话直接上了屏幕", (char *)0);
    return 127;
}
EOF

gcc -O2 -o redir redir.c
rm -f out.txt

plain_out=$(./redir plain)     # 直接 exec echo
duped_out=$(./redir duped)     # fork 之后先 dup2，再 exec echo

printf '\n  这个实验要回答：fork 和 exec 中间空出来的那一步，有什么用？\n\n'
printf '  同一句 echo 跑两次，只有 exec 之前那一步不同：\n\n'
printf '    第一次  直接 exec echo，什么都不改\n'
printf '            屏幕上：%s\n' "${plain_out:-（空）}"
printf '            out.txt：不存在\n\n'
printf '    第二次  fork 之后先 dup2，把自己的标准输出改成 out.txt，才 exec echo\n'
printf '            屏幕上：%s\n' "${duped_out:-（空）}"
printf '            out.txt：%s\n' "$(cat out.txt)"
cat <<'EOF'

  差别全在 exec 之前那一步：echo 根本不知道有文件这回事，是*子进程*先把自己的
  标准输出改掉，再让 exec 换进来的 echo 接着用 —— 你敲的每个 > 和 | 都是这么实现的。

  用在哪：分成两步是*故意*的，中间那一步留给布置 —— 09 的 zygote 干脆不 exec，
  直接 fork 一个布置好的进程出来。
EOF
