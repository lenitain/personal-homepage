#!/bin/bash
# python-split.sh — where Python's 21 ms actually goes.
#
# "Python is slow to start" is not a useful statement on its own. Adding one
# import at a time separates three different costs: the interpreter coming up,
# each stdlib module's import, and the program's own work. Measured the same way
# as everything else (taskset-pinned, median of round minimums).
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
OUT="${1:-out/python-split}"
CPU="${CPU:-6}"
mkdir -p "$OUT"

eval "$(./mkfake.sh pysplit)"
trap 'kill "$FAKE_PID" 2>/dev/null' EXIT

printf 'label\tmin_us\tp50_us\tdelta_min_us\n' >"$OUT/summary.tsv"

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

base=""
measure() { # $1 = label, rest = argv
    local label="$1"; shift
    local mins=() p50s=()
    for _ in 1 2 3; do
        local out
        out=$(taskset -c "$CPU" ./bin/bench 500 200 "$@")
        mins+=("$(awk -F'\t' '$1=="min_us"{print $2}' <<<"$out")")
        p50s+=("$(awk -F'\t' '$1=="p50_us"{print $2}' <<<"$out")")
    done
    local m p d
    m=$(median "${mins[@]}"); p=$(median "${p50s[@]}")
    if [[ -z "$base" ]]; then base="$m"; fi
    d=$(awk -v a="$m" -v b="$base" 'BEGIN{printf "%.1f", a-b}')
    printf '%s\t%s\t%s\t%s\n' "$label" "$m" "$p" "$d" >>"$OUT/summary.tsv"
    printf '  %-36s min=%-10s (+%s)\n' "$label" "$m" "$d" >&2
}

measure "python3 -c pass"                 /usr/bin/python3 -c 'pass'
measure "python3 -c import os"            /usr/bin/python3 -c 'import os'
measure "python3 -c import socket"        /usr/bin/python3 -c 'import socket'
measure "python3 -c import json"          /usr/bin/python3 -c 'import json'
measure "python3 -c import json,socket"   /usr/bin/python3 -c 'import json, socket'
measure "qb-open.py (full)"               "$PWD/bin/qb-open-python" 'https://example.com/bench?q=1'

echo >&2
echo "written to $OUT/summary.tsv" >&2
