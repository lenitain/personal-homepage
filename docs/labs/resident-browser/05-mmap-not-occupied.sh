#!/bin/bash
# 实验：映射 1 GiB，物理内存一点没涨
#
# 承接 04 —— 那里量到所有进程的地址空间加起来是物理内存的几百倍，说明那些地址
# 只是一串编号。这一份接着问：把一段文件「映射」进来，占不占物理内存？
#
# mmap 只是登记了一句「这一段编号，内容去磁盘上那个文件的这一段取」。
# 真正把内容拿进来，是碰到它的那一刻 —— 碰多少，涨多少。
# 内核装载可执行文件用的就是这套动作。
#
# 这个脚本不打印结论。它让*同一个进程*先映射、再读，中间停下来，
# 你在监视器里看着它那两个数怎么动。
#
# 关键细节：进程读完不能退出（退出了你还看什么），
# 而且放行那一下得由外面控制（一根 fifo），不然你还没打开监视器它就读完了。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程里面有什么」。
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

# 停下来。让读者看一眼屏幕，或者先猜一下结果 —— 结论要他自己看见才算数。
# 非交互跑（管道、CI）时跳过等待。
pause() {
    printf '\n      ┌ %s\n' "$1"
    printf '      └ '
    if [ -t 0 ]; then printf '想好了按回车 '; read -r _; else printf '（非交互，跳过）'; fi
    printf '\n'
}

cat >usemap.c <<'EOF'
/* 用法: usemap <文件> <映射 MiB> <读 MiB>
 *
 * 映射，报到 —— 然后卡在 stdin 上等你放行；拿到一行就把前 N MiB 读一遍，
 * 再报到，最后停住不走。两个数都从 /proc/self/status 读，不带任何加工。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define MiB (1024UL * 1024)

static void report(const char *tag)
{
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    unsigned long vsz = 0, rss = 0;
    while (f && fgets(line, sizeof line, f)) {
        if (!strncmp(line, "VmSize:", 7)) sscanf(line + 7, "%lu", &vsz);
        else if (!strncmp(line, "VmRSS:", 6)) sscanf(line + 6, "%lu", &rss);
    }
    if (f) fclose(f);
    /* 汉字占两列，printf 的 %-14s 按字节补空格，对不齐，所以自己补 */
    int w = 0;
    for (const char *q = tag; *q; q++)
        if ((*q & 0xC0) != 0x80) w += (*q & 0x80) ? 2 : 1;
    printf("  %s%*s 地址空间 %9.1f MiB    物理内存 %9.1f MiB\n",
           tag, 15 - w, "", vsz / 1024.0, rss / 1024.0);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "用法: %s <文件> <映射 MiB> <读 MiB>\n", argv[0]); return 2; }
    size_t map_len = strtoul(argv[2], NULL, 10) * MiB;
    size_t read_len = strtoul(argv[3], NULL, 10) * MiB;
    char line[64];

    report("起点");
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    /* MAP_PRIVATE + 只读 —— 跟内核装载可执行文件的代码段是同一个用法 */
    char *p = mmap(NULL, map_len, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }

    char tag[64];
    snprintf(tag, sizeof tag, "mmap %zu MiB", map_len / MiB);
    report(tag);
    if (!fgets(line, sizeof line, stdin)) return 0;   /* 等人放行 */

    volatile unsigned long sum = 0;
    for (size_t i = 0; i < read_len; i += 4096)
        sum += p[i];                  /* 每一页读一个字节，把这一页取进来 */
    if (sum == 42) puts("");          /* 别让编译器把上面这个循环优化掉 */

    snprintf(tag, sizeof tag, "读过 %zu MiB", read_len / MiB);
    report(tag);
    printf("  这段内容在地址空间里的位置：%p\n", (void *)p);
    fflush(stdout);

    sleep(1000000);                   /* 停在这儿，等你看够 */
    return 0;
}
EOF

gcc -O2 -o usemap usemap.c
truncate -s 1024M big.bin

mkfifo gate
./usemap big.bin 1024 256 >trace.txt 2>&1 <gate &
pids+=("$!")
exec 3>gate
for _ in $(seq 1 100); do [[ -s trace.txt ]] && break; sleep 0.1; done
pid=$(pgrep -P $$ -x usemap | head -1)

echo go >&3
for _ in $(seq 1 200); do grep -q '读过' trace.txt && break; sleep 0.1; done
exec 3>&-

row() { grep "$1" trace.txt | sed 's/^  //'; }

cat <<EOF

  这个实验要回答：映射一个 1 GiB 的文件，物理内存会跟着涨吗？

  同一个进程的三个时刻：
  $(row 起点)
  $(row 'mmap 1024')
  $(row '读过 256')

  映射只是登记「这段地址的内容，去磁盘上那个文件取」—— 不读文件，也不分配内存。
  碰到才读，碰多少页涨多少页。

  内核装载可执行文件用的就是这套动作。「execve 把文件搬进内存」是错的：它没有搬。

  （进程停在 pid $pid，想自己看：grep -E 'VmSize|VmRSS' /proc/$pid/status）
EOF

if [ -t 0 ]; then printf '\n  看完按回车收工 '; read -r _; printf '\n'; fi
