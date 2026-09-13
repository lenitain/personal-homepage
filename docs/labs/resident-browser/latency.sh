#!/bin/bash
# latency.sh — stable latency numbers on a machine that is not idle.
#
# Two problems with a single timed loop:
#
#   1. The box has a real desktop session on it (load average ~5), so a single
#      run's median includes whatever else was running. Running R rounds and
#      taking the median of the round medians throws most of that away.
#   2. The minimum is arguably the better estimator of intrinsic cost: it is the
#      run that got interfered with least. Both are reported, and the floor
#      binary makes clear how much of either number is just fork+exec+wait.
#
# Everything is pinned with taskset so the harness stops migrating between cores
# mid-measurement.
#
# usage: latency.sh <outdir> [rounds] [iters]
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
OUT="${1:-out/latency}"
ROUNDS="${2:-3}"
ITERS="${3:-500}"
CPU="${CPU:-6}"
mkdir -p "$OUT"

eval "$(./mkfake.sh latency)"
trap 'kill "$FAKE_PID" 2>/dev/null' EXIT

printf 'label\tmin_us\tp50_us\tp90_us\tmaxrss_kb\tminflt\n' >"$OUT/summary.tsv"

# median of a whitespace-separated list
median() {
    printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'
}

measure() { # $1 = label, rest = argv
    local label="$1"; shift
    local mins=() p50s=() p90s=() rss="" mf=""
    for _ in $(seq 1 "$ROUNDS"); do
        local out
        out=$(taskset -c "$CPU" ./bin/bench "$ITERS" 200 "$@")
        mins+=("$(awk -F'\t' '$1=="min_us"{print $2}' <<<"$out")")
        p50s+=("$(awk -F'\t' '$1=="p50_us"{print $2}' <<<"$out")")
        p90s+=("$(awk -F'\t' '$1=="p90_us"{print $2}' <<<"$out")")
        rss=$(awk -F'\t' '$1=="maxrss_kb"{print $2}' <<<"$out")
        mf=$(awk -F'\t' '$1=="minflt_per_run"{print $2}' <<<"$out")
    done
    local m p q
    m=$(median "${mins[@]}"); p=$(median "${p50s[@]}"); q=$(median "${p90s[@]}")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$m" "$p" "$q" "$rss" "$mf" >>"$OUT/summary.tsv"
    printf '  %-26s min=%-9s p50=%-9s p90=%s\n' "$label" "$m" "$p" "$q" >&2
}

echo "floor (只 fork+exec+wait，程序本身只 exit):" >&2
measure "floor-exit" "$PWD/bin/floor-exit"

echo "对照组:" >&2
measure "/bin/true (dynamic glibc)" /bin/true

echo "launcher 变体:" >&2
for b in bin/qb-open-*; do
    measure "$(basename "$b")" "$PWD/$b" 'https://example.com/bench?q=1'
done

echo >&2
echo "written to $OUT/summary.tsv" >&2
