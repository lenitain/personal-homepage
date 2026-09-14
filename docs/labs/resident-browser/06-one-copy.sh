#!/bin/bash
# 实验：100 个进程同时加载同一个库，物理内存里只有一份
#
# 两个细节是必须的，不然这个实验看不出任何东西：
#
#   一、进程读完不能退出，要停在那儿。退出了你还看什么。
#   二、库必须放在*真实磁盘*上，不能放 /tmp。
#       本机的 /tmp 是 tmpfs —— 文件本身就是内存，从建出来那一刻就占着 RAM。
#       放在那儿的话，「读一遍」不会让内存有任何变化，实验就废了。
#       所以工作目录故意开在 $HOME/.cache 下，而不是 mktemp 默认的 /tmp。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程里面有什么」。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# 库的大小。默认 2 GiB —— 够大到让「一人一份」在算术上不可能。
SIZE_MB=${1:-2048}
N=100

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$CACHE"
WORK=$(mktemp -d "$CACHE/resident-browser-lab.XXXXXX")
pids=()

cleanup() {
    (( ${#pids[@]} )) && kill "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cd "$WORK"

if [ "$(stat -f -c %T .)" = tmpfs ]; then
    echo "工作目录落在 tmpfs 上（$WORK）—— 这个实验会看不出效果。" >&2
    echo "设一个在真实磁盘上的 XDG_CACHE_HOME 再跑。" >&2
    exit 2
fi

avail_mb=$(df -Pm . | awk 'NR==2 {print $4}')
if (( avail_mb < SIZE_MB + 512 )); then
    SIZE_MB=$(( SIZE_MB / 2 ))
    echo "空间不够，库缩到 ${SIZE_MB} MiB" >&2
fi

# 整机：已用 = 总量 - 可用，缓存 = Cached。跟 btop 读的是同一个 /proc/meminfo。
meminfo() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^Cached:/{c=$2}
         END { printf "%d %d\n", (t-a)/1024, c/1024 }' /proc/meminfo
}

# 这些进程自己报的常驻内存，加起来（kB）
reported() {
    local f=() pid
    for pid in "${pids[@]}"; do f+=("/proc/$pid/smaps_rollup"); done
    (( ${#f[@]} )) || { echo 0; return; }
    awk '/^Rss:/{s+=$2} END{print s+0}' "${f[@]}" 2>/dev/null || echo 0
}

gib() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }

# ---------------------------------------------------------------- 造素材

cat >libbig.c <<'EOF'
/* 一个很大的共享库：SIZE_MB 的只读数据。
   注意是真的写进文件，不是稀疏的洞 —— 读它要走真正的页缓存。 */
__attribute__((used, section(".bigdata")))
const unsigned char big[SIZE_MB * 1024UL * 1024] = {1};
EOF

cat >big.ld <<'EOF'
/* 为什么需要这个：x86-64 默认的小代码模型假设整份文件在 2 GiB 以内，
   .text 和 .data 之间靠 PC 相对寻址（±2 GiB）。这块 2 GiB 的数据要是按默认
   顺序排在 .text 和 .bss 中间，后面那些预编译好的启动目标文件就够不着了 ——
   链接会报 "relocation truncated to fit"。把它单独放进一个段、排到 .bss 之后，
   前面那些东西的相对距离就恢复正常了。 */
SECTIONS { .bigdata : { *(.bigdata) } }
INSERT AFTER .bss;
EOF

cat >usebig.c <<'EOF'
/* 用法: usebig <lib.so> <dropcache|map|read> [hold]
 *
 * dropcache  把这个文件从页缓存里赶出去（刚写完的库还在内存里，赶不走就看不见它被读进来）
 * map/read   dlopen 那个库；read 再把 big 逐页读一遍。然后打印它落在地址空间的哪里，
 *            就停在这儿不退出 —— 实验要你盯着这个进程看，它得活着。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) return 2;

    if (!strcmp(argv[2], "dropcache")) {
        int fd = open(argv[1], O_RDONLY);
        if (fd < 0) { perror("open"); return 1; }
        posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
        close(fd);
        return 0;
    }

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    unsigned char *p = dlsym(h, "big");
    if (!p) { fprintf(stderr, "找不到符号 big\n"); return 1; }

    if (!strcmp(argv[2], "read")) {
        unsigned long sum = 0;
        for (size_t i = 0; i < (size_t)SIZE_MB * 1024 * 1024; i += 4096)
            sum += p[i];          /* 每一页读一个字节，把这一页取进来 */
        if (sum == 42) puts("");  /* 别让编译器把上面这个循环优化掉 */
    }

    printf("%p\n", (void *)p);
    fflush(stdout);
    pause();
    return 0;
}
EOF

gcc -O1 -DSIZE_MB="$SIZE_MB" -shared -fPIC -Wl,-T,big.ld -o libbig.so libbig.c
gcc -O2 -DSIZE_MB="$SIZE_MB" -o usebig usebig.c -ldl

# 刚写完的库整份都还在页缓存里。不赶走它，"读一遍"这个动作在监视器上就不会有任何变化 ——
# 读者会以为实验坏了。sync 先把脏页落盘（脏页赶不走），再 fadvise DONTNEED。
sync
./usebig ./libbig.so dropcache

# ---------------------------------------------------------------- 开演

read -r base_used base_cached < <(meminfo)

# ---- 第一步：一个进程

./usebig ./libbig.so read hold >one.txt &
pids+=("$!")
for _ in $(seq 1 600); do [[ -s one.txt ]] && break; sleep 0.1; done

read -r one_used one_cached < <(meminfo)
one_reported=$(reported)

# ---- 第二步：一百个进程

for _ in $(seq 2 "$N"); do
    ./usebig ./libbig.so read hold >/dev/null &
    pids+=("$!")
done
sleep 2   # 等它们都读完

read -r all_used all_cached < <(meminfo)
all_reported=$(reported)

first_pid=${pids[0]}

cat <<EOF

  这个实验要回答：$N 个进程把同一个 $SIZE_MB MiB 的库各读一遍，物理内存里有几份？

  三次读数（都是同一时刻的整机数字；库已经落盘，并从页缓存里赶出去了）：
  基线（还没起进程）   整机已用 $(gib $(( base_used * 1024 ))) GiB   页缓存 $(gib $(( base_cached * 1024 ))) GiB
  读完 1 个进程        整机已用 $(gib $(( one_used * 1024 ))) GiB   页缓存 $(gib $(( one_cached * 1024 ))) GiB   它自报 $(gib "$one_reported") GiB
  $N 个进程都读完     整机已用 $(gib $(( all_used * 1024 ))) GiB   页缓存 $(gib $(( all_cached * 1024 ))) GiB   各报 $(gib "$one_reported") GiB，加起来 $(gib "$all_reported") GiB

  页缓存从 $(gib $(( base_cached * 1024 ))) 涨到 $(gib $(( one_cached * 1024 ))) 的那 $(gib $(( (one_cached - base_cached) * 1024 )) ) GiB，是库被读进来 —— *一份*。
  再加 $(( N - 1 )) 个进程各自读完，页缓存一点没涨；可这 $N 个进程自己报的加起来是 $(gib "$all_reported") GiB。
  报的是「约定」的和，不是物理内存 —— 同一批物理页，被 $N 个进程各映射了一次。

  这用在哪：「只付一次」的物质基础就是这一条 —— 内容只进来一份，谁要用，谁映射它。
  fork 便宜也是同一条：它复制的正是这堆约定，不是约定指向的物理页。

  （$N 个 usebig 都停在 pid $first_pid 起，想自己看：grep -E 'VmSize|VmRSS' /proc/$first_pid/status）
EOF
