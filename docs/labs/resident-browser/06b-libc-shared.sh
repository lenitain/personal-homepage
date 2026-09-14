#!/bin/bash
# 实验：同一份 libc，被六个进程同时用着，物理内存里只有一份
#
# 06 用自己造的大库证明了「同一个文件的页可以被很多进程共用」。这一份不用造素材：
# 直接量机器上真实的 libc —— 那正是「别人也在用」那一类的实例。
#
# 看什么：
#
#   smaps 里每个映射有两笔账：
#     Rss  这一片刻在页表里、此刻真在内存里的页，一共多少 —— 数的是「页表说法」
#     Pss  那些和其他进程共用的页，按共用它的进程数均摊之后，算到自己头上多少
#   Pss 是把「有几个进程在共用这一页」这个除法先做完了才给你的。所以
#   *把多个进程的 Pss 加起来*，得到的就是真金白银的物理内存；而 Rss 加起来什么都不是。
#
# 哪个细节不做，这个实验就什么都看不出来：
#
#   一、进程必须活着。读的是 /proc/<pid>/smaps，进程一退，账就没了。
#   二、必须看 Pss，不能只看 Rss。六个进程的 Rss 会一本正经地各报 1.3 MiB ——
#      那正是「一百个进程各报 2 GiB」那个错觉的小号版本。
#   三、拿真实的共享库，别拿自己造的小 .so：真库的页涉及的进程多，
#      Pss 和 Rss 的差距才大得一眼看得出。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程里面有什么」。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

N=${1:-6}
LIB=${2:-$(ldd /bin/sh | awk '/libc\.so/{print $3; exit}')}
[ -n "$LIB" ] && [ -r "$LIB" ] || { echo "找不到 libc" >&2; exit 2; }

WORK=$(mktemp -d)
pids=()
cleanup() {
    (( ${#pids[@]} )) && kill "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cat >"$WORK/hold.c" <<'EOF'
/* 一个什么都不干的进程：exec 起来，把 libc 拿到手，然后停在那儿。
   它停着不动，是为了让外面能对着一份活着的地址空间读数。 */
#include <stdio.h>
#include <unistd.h>
int main(void) { printf("ready\n"); fflush(stdout); pause(); return 0; }
EOF
gcc -O2 -o "$WORK/hold" "$WORK/hold.c"

# 该库的映射，一条条读。一个映射报三笔账：
#   映射 = Size（页表里登记了多大）  驻留 = Rss（真在内存里多少）
#   摊到自己头上 = Pss（共用的部分按人数除过之后，算它多少）
libc_of() {
    awk -v lib="$LIB" -v pid="$1" '
        index($0, lib) { inlib = 1; next }
        inlib && /^[0-9a-f]+-/ { inlib = 0 }
        inlib && /^Size:/ { size += $2 }
        inlib && /^Rss:/  { rss  += $2 }
        inlib && /^Pss:/  { pss  += $2 }
        END { printf "%s %d %d %d\n", pid, size, rss, pss }' "/proc/$1/smaps"
}

for _ in $(seq 1 "$N"); do
    "$WORK/hold" >/dev/null &
    pids+=("$!")
done
sleep 1   # 等它们各自 exec 完

rows=()
for p in "${pids[@]}"; do
    rows+=("$(libc_of "$p")")
done

read -r one_pid one_size one_rss one_pss <<<"${rows[0]}"

read -r tot_size tot_rss tot_pss < <(printf '%s\n' "${rows[@]}" |
    awk '{s += $2; r += $3; p += $4} END {printf "%d %d %d\n", s, r, p}')

file_kb=$(( ($(stat -c %s "$LIB") + 1023) / 1024 ))

mib() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1024}'; }

cat <<EOF

  这个实验要回答：一个真实存在的动态库，被好几个进程同时用着，物理内存里有几份？

  $(basename "$LIB")，文件 $file_kb KiB。$N 个进程各自 exec 了一份，都活着：

  每个进程自己的三个数（从 /proc/<pid>/smaps 现读；$N 个进程报的数一模一样）：
    映射 $one_size KiB   驻留 $one_rss KiB   摊到自己头上 $one_pss KiB

  $N 个进程加起来：
    映射              $(mib "$tot_size") MiB    ← 页表里登记的，$N 份
    驻留（Rss 相加）  $(mib "$tot_rss") MiB    ← 每个进程都这么报，加起来是个假数
    摊到自己头上相加  $(mib "$tot_pss") MiB    ← 这才是这 $N 个进程合起来真花的物理内存

  Pss 是内核把「这一页有几个进程在共用」除完了才给你的；Rss 不是，所以第二笔账不能相加。
  $N 个进程把同一批页各映射了一遍，物理上只有一份 —— 这就是「动态链接库复用」本身，
  它不是设计意图，是能读出来的数。

  同一批数里还带着第三种情况：一个进程把 $(mib "$one_size") MiB 登记进了地址空间，
  真驻留的只有 $(mib "$one_rss") MiB —— 剩下的页在页表里，物理内存里还没有，
  碰它的那一刻才去磁盘取（05 量过这件事）。

  （进程停在 pid ${pids[0]} 起，想自己看：grep -E 'Size|Rss|Pss' /proc/${pids[0]}/smaps）
EOF
