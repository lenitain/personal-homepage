#!/bin/bash
# verify.sh — every variant must produce byte-identical IPC messages to the
# shipped C binary. A launcher that is fast because it sends the wrong bytes is
# not a launcher, so this gates the benchmark.
#
# Note the deliberate distinction between "no-args" (argc == 1) and "empty-arg"
# (argc == 2, argv[1] == ""). Both serialise to "args":[""], but they take
# different branches, so both get tested.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
mkdir -p out

REF=bin/qb-open-c-musl-static

CASES=(
    two-args
    no-args
    empty-arg
    quotes-backslash
    newline-tab
    control-chars
    raw-utf8
    long-arg
)

run_case() { # $1 = binary, $2 = case name
    local b="$1"
    case "$2" in
    two-args) "$b" 'https://example.com/a b?q=1' 'second' ;;
    no-args) "$b" ;;
    empty-arg) "$b" '' ;;
    quotes-backslash) "$b" 'q"uo\te' ;;
    newline-tab) "$b" "$(printf 'a\nb\tc')" ;;
    control-chars) "$b" "$(printf 'x\001\002\037y')" ;;
    raw-utf8) "$b" 'unicode:中文→' ;;
    long-arg) "$b" "$(printf 'A%.0s' $(seq 1 2000))" ;;
    *) echo "unknown case $2" >&2; return 1 ;;
    esac
}

capture() { # $1 = binary, $2 = output file
    eval "$(./mkfake.sh "verify-$$")"
    local d="$XDG_RUNTIME_DIR"
    for c in "${CASES[@]}"; do run_case "$PWD/$1" "$c"; done
    sleep 0.3
    kill "$FAKE_PID" 2>/dev/null
    wait "$FAKE_PID" 2>/dev/null
    cp "$d/messages" "$2"
}

capture "$REF" out/ref-messages

fail=0
printf '%-28s' "variant"
for c in "${CASES[@]}"; do printf '%-18s' "$c"; done
echo

for b in bin/qb-open-*; do
    label="$(basename "$b")"
    [[ "$label" == "$(basename "$REF")" ]] && continue

    printf '%-28s' "$label"
    capture "$b" "out/got-$label"

    mapfile -t got <"out/got-$label"
    mapfile -t want <out/ref-messages

    ok=1
    for i in "${!CASES[@]}"; do
        if [[ "${got[$i]:-}" == "${want[$i]:-}" ]]; then
            printf '%-18s' "PASS"
        else
            printf '%-18s' "FAIL"
            ok=0
        fi
    done
    echo
    if [[ $ok -eq 0 ]]; then
        fail=1
        echo "  ---- $label: reference vs actual ----" >&2
        diff <(printf '%s\n' "${want[@]}") <(printf '%s\n' "${got[@]}") | head -8 >&2
    fi
done

echo
if [[ $fail -eq 0 ]]; then
    echo "ALL VARIANTS MATCH THE REFERENCE"
else
    echo "SOME VARIANTS DIVERGE"
fi
exit $fail
