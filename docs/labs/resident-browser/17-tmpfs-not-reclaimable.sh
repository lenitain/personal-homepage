#!/bin/bash
# 实验：内存不够的时候，内核动得了谁、动不了谁？
#
# 这是「数据该留在磁盘还是搬进内存」那个决定里真正的那一半。
# 16 说的是「留在磁盘上不等于每次读盘」；这一份说另一半：
# 磁盘上的内容内核随时丢得掉，tmpfs 里的内容丢不掉 —— 它没地方可去。
#
# 怎么看：把自己关进一个**内存上限很小**的 cgroup，在里面做三件事。
#
#   A  写一个比上限还大的普通文件。写得下去 —— 脏页写回磁盘就腾出地方了。
#   B  读一个比上限还大的文件，读两遍。第一遍读盘，第二遍 0 ——
#      文件页回收掉之后，下次读回来就是。
#   C  写一个比上限还大的 tmpfs 文件。写不下去 —— tmpfs 的页没有后备存储，
#      内核腾不出地方，只能把写的人杀掉。
#
#   三个用例关在同一个笼子里，差别只可能来自「这一页有没有地方可去」。
#
# 笼子用 systemd 的临时 scope 做（需要 systemd --user 与 memory 控制器）。
# 全程不需要 root，跑完不留残留。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# 数据目录必须在**有后备存储**的文件系统上：这台机器的 /tmp 就是 tmpfs，
# 在那里造素材等于把用例 A 也变成 tmpfs 用例，三个用例的差别就没了。
pick_disk_dir() {
    local base
    for base in "${DISK_DIR_OVERRIDE:-}" /var/tmp "$HOME" /; do
        [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
        [ "$(findmnt -no FSTYPE -T "$base" 2>/dev/null || true)" != "tmpfs" ] || continue
        mktemp -d "$base/.tmpfs-lab-XXXXXX" && return 0
    done
    return 1
}

WORK=$(pick_disk_dir) || {
    printf '\n  跳过：找不到一个可写的、非 tmpfs 的目录来放数据。\n\n'; exit 0
}
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

LIMIT_MB="${LIMIT_MB:-64}"     # cgroup 的内存上限
SIZE_MB="${SIZE_MB:-256}"      # 每个用例要动的数据量（远大于上限）

if ! command -v systemd-run >/dev/null; then
    printf '\n  跳过：需要 systemd-run（systemd --user）。\n\n'; exit 0
fi

# 找一个 tmpfs 目录，容量够放 SIZE_MB
TMPFS_DIR=""
for cand in "${TMPFS_DIR_OVERRIDE:-}" /dev/shm "${XDG_RUNTIME_DIR:-}"; do
    [ -n "$cand" ] && [ -d "$cand" ] && [ -w "$cand" ] || continue
    [ "$(findmnt -no FSTYPE -T "$cand" 2>/dev/null || true)" = "tmpfs" ] || continue
    avail_mb=$(( $(df -k --output=avail "$cand" 2>/dev/null | tail -1) / 1024 ))
    [ "$avail_mb" -ge $(( SIZE_MB + 64 )) ] || continue
    TMPFS_DIR="$cand"; break
done
[ -n "$TMPFS_DIR" ] || { printf '\n  跳过：找不到容量够的用户可写 tmpfs。\n\n'; exit 0; }

# 先确认笼子建得起来再做别的
if ! systemd-run --user --scope --quiet -p MemoryMax="${LIMIT_MB}M" -p MemorySwapMax=0 \
        /bin/true >/dev/null 2>&1; then
    printf '\n  跳过：建不起带内存上限的临时 scope（需要 systemd --user 与 memory 控制器）。\n\n'
    exit 0
fi

cat >"$WORK/cases.sh" <<'INNER'
#!/bin/bash
# 整个脚本跑在笼子里。$1 = 用例，$2 = 数据目录，$3 = tmpfs 目录，$4 = MiB
set -uo pipefail
case_name="$1"; data_dir="$2"; tmp_dir="$3"; mb="$4"
disk="$data_dir/scratch.bin"; tmpf="$tmp_dir/resident-browser-lab-$$.bin"
trap 'rm -f "$disk" "$tmpf"' EXIT

printf '    笼子：内存上限 %s MiB，swap 关掉\n' "${LIMIT_MB}"

case "$case_name" in
A)
    printf '    A  写一个 %s MiB 的普通文件（远大于上限）\n' "$mb"
    if dd if=/dev/zero of="$disk" bs=1M count="$mb" status=none 2>/dev/null; then
        sync
        printf '        写完了，%s —— 脏页写回磁盘就把地方腾出来了\n' "$(du -h "$disk" | cut -f1)"
    else
        printf '        没写完（退出码 %s）—— 不该发生\n' "$?"
    fi
    ;;
B)
    printf '    B  读一个 %s MiB 的文件，连读两遍（上限只有 %s MiB）\n' "$mb" "${LIMIT_MB:-?}"
    before=$(awk '/^read_bytes:/{print $2}' /proc/self/io)
    cat "$data_dir/source.bin" >/dev/null
    mid=$(awk '/^read_bytes:/{print $2}' /proc/self/io)
    cat "$data_dir/source.bin" >/dev/null
    after=$(awk '/^read_bytes:/{print $2}' /proc/self/io)
    first=$(( (mid - before) / 1024 )); second=$(( (after - mid) / 1024 ))
    printf '        两遍都读完了 —— 比上限大四倍的文件，读得下去\n'
    printf '        第一遍读盘 %s KiB，第二遍读盘 %s KiB\n' "$first" "$second"
    if [ "$first" -eq 0 ]; then
        printf '        （这一遍没读盘：文件页还在缓存里，这台机器的文件系统不肯丢\n'
        printf '          刚写过的文件。要看的结论不依赖它：它读得下去本身就说完了\n'
        printf '          事 —— 文件页随时可以回收，所以再大也能读。）\n'
    fi
    ;;
C)
    printf '    C  写一个 %s MiB 的 tmpfs 文件（远大于上限）\n' "$mb"
    if dd if=/dev/zero of="$tmpf" bs=1M count="$mb" status=none 2>/dev/null; then
        printf '        居然写完了 —— 这台机器的 tmpfs 没算进这个 cgroup（少见）\n'
    else
        printf '        写不下去，进程被内核杀了（退出码 %s）\n' "$?"
        printf '        tmpfs 的页没有后备存储，腾不出地方，只能杀掉写的人\n'
    fi
    ;;
esac
INNER
chmod +x "$WORK/cases.sh"

run_case() {
    systemd-run --user --scope --quiet \
        -p MemoryMax="${LIMIT_MB}M" -p MemorySwapMax=0 \
        --setenv=LIMIT_MB="$LIMIT_MB" \
        "$WORK/cases.sh" "$1" "$WORK" "$TMPFS_DIR" "$SIZE_MB" 2>&1 | sed 's/^/  /'
    printf '    → 用例 %s 结束\n\n' "$1"
}

printf '\n  这个实验要回答：内存不够的时候，哪些页内核动得了？\n\n'
printf '  三个用例关在同一个 %s MiB 的笼子里，每个都要动 %s MiB 数据。\n' \
    "$LIMIT_MB" "$SIZE_MB"
printf '  笼子外的数据目录：%s（%s）\n  笼子外的 tmpfs：%s\n\n' \
    "$WORK" "$(findmnt -no FSTYPE -T "$WORK")" "$TMPFS_DIR"

# B 的素材要在笼子外造好，否则造素材本身就撞上限
if ! dd if=/dev/zero of="$WORK/source.bin" bs=1M count="$SIZE_MB" status=none; then
    printf '  造素材失败（磁盘空间不够？）。\n\n'; exit 1
fi

run_case A
run_case B
run_case C

cat <<'EOF'
  三个用例的差别只有一处：**这些页有没有地方可去。**

    A  文件页 —— 写回磁盘就行，所以内核随时腾得出来
    B  文件页 —— 丢掉之后下次读回来就行（第一遍读盘，第二遍 0）
    C  tmpfs 页 —— 磁盘上没有那一份，丢不掉，于是内核只能杀进程

  用在哪：这就是「把 profile 按进 tmpfs」的代价。你不是让它更快，
  是把它从「可回收」改成了「钉死的」——
  而它留在磁盘上本来也好好的：内核会按热度自己决定留不留（16 量的是这个）。

  C 的失败方式值得记住：不是「慢」，是*写到一半被杀*。
  所以「内存都是内存」这句话在这里不成立。
EOF
