#!/bin/bash
# measure.sh — run the full measurement matrix over every launcher variant.
#
#   ./measure.sh <outdir> [iters]
#
# Produces, per binary:
#   <label>.strace-c.txt   strace -c summary (authoritative syscall breakdown)
#   <label>.strace.txt     full syscall trace (for the histogram + totals)
#   <label>.maps.txt       address space at the post-execve stop
#   <label>.execmap.log    the same, raw
# plus a summary.tsv with one row per binary.
#
# Timing is deliberately NOT taken under strace: ptrace adds orders of magnitude
# of overhead and would measure the tracer, not the launcher.
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
OUT="${1:?usage: measure.sh <outdir> [iters]}"
ITERS="${2:-1000}"
WARMUP=200
URL='https://example.com/bench?q=1'
mkdir -p "$OUT"

eval "$(./mkfake.sh measure)"
trap 'kill "$FAKE_PID" 2>/dev/null' EXIT

printf 'label\tsize_bytes\tsize_stripped\tkind\tinterp\tneeded\tp50_us\tp90_us\tp99_us\tmaxrss_kb\tsyscalls\tsys_unique\tvma_count\tvma_kb\trss_kb\n' >"$OUT/summary.tsv"

# Size after strip, for ELF only. `strip` on a script would eat it.
stripped_size() {
    local f="$1" tmp
    if ! head -c4 "$f" | grep -q $'\x7fELF'; then
        echo 0
        return
    fi
    tmp=$(mktemp)
    cp "$f" "$tmp" && strip "$tmp" 2>/dev/null
    stat -c%s "$tmp"
    rm -f "$tmp"
}

for b in bin/qb-open-*; do
    label="$(basename "$b")"
    printf '%-28s' "$label" >&2

    size=$(stat -c%s "$b")
    ssize=$(stripped_size "$b")

    # INTERP is the authoritative static/dynamic test: `file` says
    # "static-pie linked" for Rust's crt-static output, which a naive
    # 'statically linked' grep misses.
    interp=$(readelf -lW "$b" 2>/dev/null | grep -c 'INTERP' || true)
    needed=$(readelf -dW "$b" 2>/dev/null | grep -c 'NEEDED' || true)
    if [[ "$label" == *python* ]]; then
        kind=script
    elif [[ "$interp" -gt 0 ]]; then
        kind=dynamic
    else
        kind=static
    fi

    # --- latency -----------------------------------------------------------
    read -r p50 p90 p99 rss < <(./bin/bench "$ITERS" "$WARMUP" "$PWD/$b" "$URL" |
        awk -F'\t' '
            $1=="p50_us"{p50=$2} $1=="p90_us"{p90=$2} $1=="p99_us"{p99=$2}
            $1=="maxrss_kb"{rss=$2}
            END{print p50, p90, p99, rss}')

    # --- syscalls ----------------------------------------------------------
    strace -c -f -o "$OUT/$label.strace-c.txt" "$PWD/$b" "$URL" >/dev/null 2>&1
    strace -f -o "$OUT/$label.strace.txt" "$PWD/$b" "$URL" >/dev/null 2>&1
    syscalls=$(grep -cE '^[0-9]+ +[a-zA-Z_0-9]+\(' "$OUT/$label.strace.txt")
    sys_unique=$(grep -E '^[0-9]+ +[a-zA-Z_0-9]+\(' "$OUT/$label.strace.txt" |
        sed -E 's/^[0-9]+ +([a-zA-Z_0-9]+)\(.*/\1/' | sort -u | wc -l)

    # --- address space at exec --------------------------------------------
    ./bin/execmap "$PWD/$b" "$URL" >"$OUT/$label.execmap.log" 2>&1
    awk '/^=== maps ===/{m=1;next} /^=== smaps_rollup/{m=0} m' \
        "$OUT/$label.execmap.log" >"$OUT/$label.maps.txt"
    read -r vma_count vma_kb < <(awk '
        { split($1, a, "-");
          kb = (strtonum("0x" a[2]) - strtonum("0x" a[1])) / 1024;
          n++; t += kb }
        END { printf "%d %d\n", n, t }' "$OUT/$label.maps.txt")
    rss_kb=$(awk '/^Rss:/{print $2}' "$OUT/$label.execmap.log")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$size" "$ssize" "$kind" "$interp" "$needed" \
        "$p50" "$p90" "$p99" "$rss" "$syscalls" "$sys_unique" \
        "$vma_count" "$vma_kb" "$rss_kb" >>"$OUT/summary.tsv"

    printf ' p50=%-9s syscalls=%-5s vma=%-3s rss=%s\n' "$p50" "$syscalls" "$vma_count" "$rss_kb" >&2
done

echo >&2
echo "summary written to $OUT/summary.tsv" >&2
