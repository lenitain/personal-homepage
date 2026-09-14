#!/bin/bash
# 演示：动态链接的开销 —— 链接器把时间花在哪
#
# 承接 07：同一个程序，动态链接比静态链接多花一百多微秒。这一份把那笔开销拆开。
#
# 用的全是 glibc 自带的 LD_DEBUG 开关，不需要 root，不需要额外工具。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# ------------------------------------------------------------------ 造素材

cat >libctor.c <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void lib_init(void) { puts("  [lib]  构造函数跑了"); }
int lib_answer(void) { return 42; }
EOF

cat >mainctor.c <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void main_init(void) { puts("  [main] 构造函数跑了"); }
int lib_answer(void);
int main(void) { printf("  [main] main() 里拿到 %d\n", lib_answer()); return 0; }
EOF

gcc -shared -fPIC -o libctor.so libctor.c
gcc -O2 -o ctor-demo mainctor.c -L. -lctor -Wl,-rpath,"$WORK"

cat >liblazy.c <<'EOF'
#include <stdio.h>
void called_sometimes(void) { puts("  这次调用了 called_sometimes"); }
void never_called(void)     { puts("  这行永远不会打印"); }
EOF

cat >mainlazy.c <<'EOF'
#include <stdio.h>
void called_sometimes(void);
void never_called(void);
int main(int argc, char **argv) {
    if (argc > 99) never_called();   /* argc 不可能到 99，这个分支永远不走 */
    called_sometimes();
    return 0;
}
EOF

gcc -shared -fPIC -o liblazy.so liblazy.c
gcc -O2 -o lazy-demo  mainlazy.c -L. -llazy -Wl,-rpath,"$WORK"
gcc -O2 -Wl,-z,now -o eager-demo mainlazy.c -L. -llazy -Wl,-rpath,"$WORK"

# ------------------------------------------------------------------ 量

LD_DEBUG=libs       ./ctor-demo  >/dev/null 2>"$WORK/libs.txt"  || true
LD_DEBUG=statistics ./ctor-demo  >/dev/null 2>"$WORK/stats.txt" || true
LD_DEBUG=bindings   ./lazy-demo  >/dev/null 2>"$WORK/lazy.txt"  || true
LD_DEBUG=bindings   ./eager-demo >/dev/null 2>"$WORK/eager.txt" || true

tries=$(grep -c 'trying file=.*libctor' "$WORK/libs.txt" || true)

init_order=$(grep -E 'calling init:|initialize program:' "$WORK/libs.txt" |
    sed -E 's/^ *[0-9]*:[[:space:]]*//;
            s/^initialize program:.*/main/;
            s/^calling init: //;
            s#.*/##' |
    paste -sd'>' -)

read -r total rel_n rel_pct load_pct < <(awk '
    /total startup time/          { t = $(NF-1) }
    /time needed for relocation/  { r = $NF; gsub(/[()%]/, "", r) }
    /number of relocations:/      { if (!n) n = $NF }
    /time needed to load objects/ { l = $NF; gsub(/[()%]/, "", l) }
    END { printf "%s %s %s %s\n", t, n, r, l }' "$WORK/stats.txt")

lazy_never=$(grep -c 'never_called'  "$WORK/lazy.txt"  || true)
eager_never=$(grep -c 'never_called' "$WORK/eager.txt" || true)

# ------------------------------------------------------------------ 输出

strip() { sed -E 's/^ *[0-9]*:[[:space:]]*//; s#/tmp/[^/]*/##g' | sed 's/^/    /'; }

cat <<'EOF'

  这个实验要回答：动态链接比静态链接多花的那一百多微秒，花在哪几件事上？
EOF

printf '\n  $ LD_DEBUG=libs ./ctor-demo\n'
grep -E 'find library=libctor|trying file=.*libctor|calling init|initialize program' \
    "$WORK/libs.txt" | strip

printf '\n  $ LD_DEBUG=statistics ./ctor-demo\n'
grep -E 'total startup time|time needed for relocation|time needed to load objects' \
    "$WORK/stats.txt" | strip

printf '\n  符号解析：同一个源文件编两遍，只差 -z now。没调用过的函数，默认绑 %s 次，-z now 绑 %s 次。\n' \
    "$lazy_never" "$eager_never"

cat <<EOF

  四件事各自的账：
    找库             libctor.so 试了 $tries 个地方才轮到（glibc-hwcaps 逐级回退）
    初始化顺序       $init_order
    重定位           $rel_n 处，占链接器时间的 $rel_pct%
    映射各 .so       占链接器时间的 $load_pct%

  链接器自己花的全部时间：$total cycles

  最贵的是「映射各 .so」—— 但那只是 mmap 登记，不是把内容读进内存（见 05）。
  这四步跟你程序做什么*无关*：程序只调了一个函数，该找的库一个不少。
  所以下一步（09）值得问一句：能不能只付一次。
EOF
