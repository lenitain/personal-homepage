#!/bin/bash
# 实验：所有进程的地址空间加起来，比物理内存大得多
#
# 承接 03 —— fork 和 execve 这两步讲完了，接下来要问 execve 那一下花在什么上。
# 要问它，先得知道一个进程「里面」有什么 —— 这一份量其中一样：地址空间有多大。
#
# 形态说明：这个实验要回答的就是「大多少倍」—— 所以跑完给一张表。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程里面有什么」。
set -euo pipefail

mem_gib=$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' /proc/meminfo)
# 进程随时在生灭：glob 展开之后那个进程可能已经退了。读不到不算实验失败，
# 所以把 awk 的非零退出咽掉（读不到的那个进程本来也没算进去）。
read -r sum_gib n_proc < <(awk '/^VmSize:/{s+=$2; n++} END{printf "%.0f %d\n", s/1048576, n}' \
    /proc/[0-9]*/status 2>/dev/null || true)
ratio=$(awk -v a="$sum_gib" -v b="$mem_gib" 'BEGIN{printf "%.0f", a/b}')

read -r top_gib top_name < <(for f in /proc/[0-9]*/status; do
    awk '/^Name:/{n=$2} /^VmSize:/{printf "%.0f %s\n", $2/1048576, n}' "$f" 2>/dev/null
done | sort -gr | head -1)
top_ratio=$(awk -v a="$top_gib" -v b="$mem_gib" 'BEGIN{printf "%.0f", a/b}')

printf '\n  这个实验要回答：所有进程的地址空间加起来，比物理内存大多少？\n\n'
printf '  这台机器上读得到的 %s 个进程，VmSize 求和：\n\n' "$n_proc"
printf '  物理内存                            %7s GiB   ← /proc/meminfo 的 MemTotal\n' "$mem_gib"
printf '  所有进程的地址空间加起来            %7s GiB   ← 读得到的 %s 个进程，VmSize 求和\n' "$sum_gib" "$n_proc"
printf '  地址空间是物理内存的                %7s 倍    ← 上面两个数相除\n' "$ratio"
printf '  最大的一个进程                      %7s GiB   ← %s，单是它就有物理内存的 %s 倍\n' \
       "$top_gib" "$top_name" "$top_ratio"
cat <<'EOF'

  这些地址要是真是内存，这台机器连一个浏览器都开不起来 —— 所以它们只是一串*编号*，
  不是物理内存：两个进程里都有 0x400000，那是两个编号碰巧长得一样，落点毫无关系。

  用在哪：记住这一点，后面 execve 那笔账才不会算错 —— 它贵的是*找*和*算*，
  不是把这些地址变成内存（07 和 08 会量）。别的用户的进程读不到，这是下限。
EOF
