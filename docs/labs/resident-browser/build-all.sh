#!/bin/bash
# build-all.sh — build every launcher variant twice: once "as a naive release
# build produces it", once stripped.
#
# Both matter and they answer different questions:
#   as-built  = what you get from the obvious command (Rust and Zig keep debug
#               info by default, which is 10-80x the actual code)
#   stripped  = what you would ship, and the fair basis for comparing startup
#               cost, since fewer pages have to be mapped
#
# The canonical binaries in bin/ are the stripped ones. Unstripped copies land in
# out/as-built/ purely so the size table can show both.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=launchers
ASBUILT=out/as-built
mkdir -p bin "$ASBUILT"

build() { # $1 = output name, rest = command
    local name="$1"; shift
    if "$@" 2>"$ASBUILT/$name.buildlog"; then
        cp "bin/$name" "$ASBUILT/$name"
        strip "bin/$name"
        printf '  ok   %-26s as-built=%-9s stripped=%s\n' "$name" \
            "$(stat -c%s "$ASBUILT/$name")" "$(stat -c%s "bin/$name")"
    else
        printf '  FAIL %-26s (see %s)\n' "$name" "$ASBUILT/$name.buildlog"
        tail -3 "$ASBUILT/$name.buildlog" >&2
        return 1
    fi
}

echo "asm (x86-64, no libc):"
as -o out/qb-open-asm.o "$SRC/qb-open.S"
ld -o bin/qb-open-asm out/qb-open-asm.o
cp bin/qb-open-asm "$ASBUILT/qb-open-asm"; strip bin/qb-open-asm
printf '  ok   %-26s as-built=%-9s stripped=%s\n' qb-open-asm \
    "$(stat -c%s "$ASBUILT/qb-open-asm")" "$(stat -c%s bin/qb-open-asm)"

echo "C (four linking variants):"
build qb-open-c-musl-static  musl-gcc -O2 -Wall -Wextra -static -o bin/qb-open-c-musl-static  "$SRC/qb-open.c"
build qb-open-c-musl-dyn     musl-gcc -O2 -Wall -Wextra         -o bin/qb-open-c-musl-dyn     "$SRC/qb-open.c"
build qb-open-c-glibc-static gcc      -O2 -Wall -Wextra -static -o bin/qb-open-c-glibc-static "$SRC/qb-open.c"
build qb-open-c-glibc-dyn    gcc      -O2 -Wall -Wextra         -o bin/qb-open-c-glibc-dyn    "$SRC/qb-open.c"

echo "Rust (std only, zero crates):"
build qb-open-rust-dyn    rustc -O -C strip=symbols -o bin/qb-open-rust-dyn "$SRC/qb-open.rs"
build qb-open-rust-static rustc -O -C strip=symbols -C target-feature=+crt-static \
                          -o bin/qb-open-rust-static "$SRC/qb-open.rs"

echo "Zig (std only, no libc):"
build qb-open-zig zig build-exe -O ReleaseFast -fstrip -femit-bin=bin/qb-open-zig "$SRC/qb-open.zig"

echo "Python (stdlib json + socket, no build step):"
install -m 755 "$SRC/qb-open.py" bin/qb-open-python
cp bin/qb-open-python "$ASBUILT/qb-open-python"
printf '  ok   %-26s as-built=%-9s stripped=%s\n' qb-open-python \
    "$(stat -c%s "$ASBUILT/qb-open-python")" "$(stat -c%s bin/qb-open-python)"

echo "测量工具（不是被测对象）:"
# bench 和 execmap 是量上面那些二进制的尺子，本身不参与对比。
# 少建它们的话，latency.sh 会对着一个不存在的 ./bin/bench 报「没有那个文件或目录」，
# measure.sh 会安静地输出一张 p50/vma/rss 全空的表 —— 那张表看起来像结果，其实什么都没量。
for tool in bench execmap; do
    cc -O2 -Wall -Wextra -o "bin/$tool" "$tool.c"
    printf '  ok   %-26s %s\n' "$tool" "$(stat -c%s "bin/$tool")"
done

echo
echo "bin/ now holds the canonical stripped builds."
