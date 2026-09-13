#!/bin/bash
# overflow-check.sh — probe the C buffer overflow around the 8 KB boundary.
#
# This MUST NOT run the shipped binary directly. If the bytes scribbled past
# `json` happen to form a valid pointer array, execve() can succeed and launch
# the real browser. So everything runs inside a private mount namespace with
# /bin/true bind-mounted over /usr/bin/qutebrowser: if the fallback fires, it
# execs coreutils' true, not a browser.
#
# usage: ./overflow-check.sh [binary]
set -uo pipefail

BIN="${1:-$HOME/.config/mise/dotfiles/.local/bin/scripts/qb-open}"
export BIN
mkdir -p ./out

unshare -rm --propagation private bash -c '
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
mount --bind /bin/true /usr/bin/qutebrowser || exit 1

export XDG_RUNTIME_DIR=./rt-overflow
rm -rf "$XDG_RUNTIME_DIR"; mkdir -p "$XDG_RUNTIME_DIR/qutebrowser"
./fake-sock.py "$XDG_RUNTIME_DIR/qutebrowser/ipc-fake" >/dev/null 2>"$XDG_RUNTIME_DIR/msgs" &
srv=$!
for _ in $(seq 1 100); do [[ -S "$XDG_RUNTIME_DIR/qutebrowser/ipc-fake" ]] && break; sleep 0.02; done

echo "binary: $BIN"
printf "%-8s %-5s %-12s %s\n" n rc bytes_sent fallback_trace
for n in 8000 8100 8110 8118 8120 8124 8130 8150 8180 8300; do
    arg=$(printf "A%.0s" $(seq 1 "$n"))
    before=$(stat -c%s "$XDG_RUNTIME_DIR/msgs")
    strace -f -o "out/ovf-$n.txt" "$BIN" "$arg" >/dev/null 2>&1
    rc=$?
    after=$(stat -c%s "$XDG_RUNTIME_DIR/msgs")

    ev=$(grep -oE "execve\(\"[^\"]*\", \[[^]]*\], 0x[0-9a-f]+\)" "out/ovf-$n.txt" | head -1)
    fb="-"
    if [[ -n "$ev" ]]; then
        ptr=${ev##*, }
        fb="execve envp=$ptr"
    fi
    printf "%-8s %-5s %-12s %s\n" "$n" "$rc" "$((after-before))" "$fb"
done

kill $srv 2>/dev/null
wait $srv 2>/dev/null
'
