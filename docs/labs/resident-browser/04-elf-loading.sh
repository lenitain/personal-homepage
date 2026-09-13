#!/bin/bash
# 演示：一个可执行文件是怎么变成进程地址空间的
#
# 全部自包含 —— 自己编两个 hello（静态一个、动态一个），然后对比。
# 不需要 root，不碰系统里任何东西。
#
# 读者要看到的三件事：
#   1. ELF 头里有什么（PT_LOAD / PT_INTERP / PT_DYNAMIC）
#   2. execve 之后内核/链接器发的系统调用序列
#   3. 那些段最终落在地址空间的哪 —— 也就是 /proc/<pid>/maps 里的那些 VMA
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

hr() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 造两个 hello

cat >hello.c <<'EOF'
#include <stdio.h>
int main(void) { puts("hello"); return 0; }
EOF

gcc -O2 -o hello-dyn hello.c
if gcc -O2 -static -o hello-static hello.c 2>/dev/null; then
    :
else
    musl-gcc -O2 -static -o hello-static hello.c
fi

# 一个把自己地址空间打出来的小工具：这些 VMA 就是前面那些段的落点
cat >maps-dump.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("%5s %s\n", "pid", "maps");
    char line[512];
    FILE *f = fopen("/proc/self/maps", "r");
    while (f && fgets(line, sizeof line, f)) fputs(line, stdout);
    return 0;
}
EOF
gcc -O2 -o maps-dyn maps-dump.c
gcc -O2 -static -o maps-static maps-dump.c 2>/dev/null || musl-gcc -O2 -static -o maps-static maps-dump.c

# ------------------------------------------------------- 1. ELF 头：两种链接

hr "1. ELF 的 program header —— 两个 hello 的差别全在这里"

for f in hello-static hello-dyn; do
    printf '\n  【%s】\n' "$f"
    readelf -lW "$f" | grep -E '^  (Type|LOAD|INTERP|DYNAMIC)' | sed 's/^/    /'
    printf '    → 请求的解释器: '
    readelf -lW "$f" | grep -oP '(?<=program interpreter: ).*(?=\])' || echo '（没有，这个文件是自足的）'
done

printf '\n  说明：\n'
printf '    PT_LOAD    要映射进地址空间的段，每段带自己的权限（R / RX / RW）\n'
printf '    PT_INTERP  有它就说明「这个文件自己跑不起来，得先请一个解释器」\n'
printf '    PT_DYNAMIC 链接器要读的那张表（依赖哪些库、重定位在哪）\n'

# ----------------------------------------------- 2. execve 之后发生了什么

hr "2. execve 之后：内核和链接器各发了哪些系统调用"

for f in hello-dyn hello-static; do
    printf '\n  【%s】\n' "$f"
    strace -f -o "$f.trace" "./$f" >/dev/null 2>&1

    # 第一条 execve 是「我们启动它」；之后才是这个程序自己做的事
    grep -nE 'execve|mmap|openat|arch_prctl|set_tid|brk' "$f.trace" |
        head -12 | sed -E 's/^([0-9]+):[0-9]+ /\1. /' | sed 's/^/    /'

    printf '    系统调用总数: %s\n' "$(grep -cE '^[0-9]+ +[a-zA-Z_0-9]+\(' "$f.trace")"
done

printf '\n  动态版那几行 mmap 值得盯着看：\n'
printf '    同一个 fd、MAP_FIXED、长度分别是 1.7M / 491K / 24K / 31K\n'
printf '    —— 那是 libc 的四个 PT_LOAD 段被逐段映射进地址空间\n'
printf '  静态版 execve 之后只剩一行 arch_prctl（设置线程局部存储），没有别的\n'

# ------------------------------------------- 3. 那些段落到了地址空间哪里

hr "3. 段最终落在哪：VMA 就是 PT_LOAD 的落点"

for f in maps-static maps-dyn; do
    printf '\n  【%s】的地址空间\n' "$f"
    ./"$f" | head -14 | sed 's/^/    /'
    printf '    … 共 %s 个 VMA\n' "$(./"$f" | grep -c '^[0-9a-f]')"
done

printf '\n  静态版：4 个 PT_LOAD 大致对应地址空间里那几段，加上 vvar/vdso/stack\n'
printf '  动态版：多出来的那一片分散的高地址映射，全是链接器后来加的\n'

# --------------------------------------------------------------- 4. 小结

hr "4. 一句话总结"

cat <<'EOF'
  内核只做一件事：把 PT_LOAD 描述的段落 mmap 进新建的地址空间。
  地址空间建好之后，如果 ELF 头里写了 PT_INTERP，内核跳转的不是这个程序，
  而是那个解释器 —— 解释器才是真正开始执行的第一段代码。
  剩下的活（找库、重定位、符号解析、调各家的 init）全是它在做。
  下一份演示（05）就看它具体在忙什么。
EOF
