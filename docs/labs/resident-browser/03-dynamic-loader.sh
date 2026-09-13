#!/bin/bash
# 演示：动态链接器到底在做什么
#
# 承接 04 —— 那里看到内核在 execve 之后就把控制权交给了 ld.so。
# 这一份把 ld.so 的活拆开看：找库、重定位、符号解析、调 init。
#
# 用的全是 glibc 自带的 LD_DEBUG 开关，不需要 root，不需要额外工具。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

hr() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

# ------------------------------------------------------------------ 造素材

cat >libctor.c <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void lib_init(void) {
    puts("  [lib]   构造函数跑了");
}
int lib_answer(void) { return 42; }
EOF

cat >mainctor.c <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void main_init(void) {
    puts("  [main]  构造函数跑了");
}
int lib_answer(void);
int main(void) {
    printf("  [main]  main() 里拿到 %d\n", lib_answer());
    return 0;
}
EOF

gcc -shared -fPIC -o libctor.so libctor.c
gcc -O2 -o ctor-demo mainctor.c -L. -lctor -Wl,-rpath,"$WORK"

# ------------------------------------------------------- 1. 它加载了哪些东西

hr "1. LD_DEBUG=libs —— 找了哪些库，按什么顺序初始化"

LD_DEBUG=libs ./ctor-demo 2>&1 | grep -E 'find library|trying file|calling init|initialize program' |
    sed 's/^ *[0-9]*: */  /' | head -16

printf '\n  注意最后两行的顺序：\n'
printf '    calling init 是**按依赖顺序**逐个调用每个目标文件的初始化函数\n'
printf '    主程序排在最后 —— 它依赖的所有东西都必须先就绪\n'

# ----------------------------------------------------------- 2. 重定位的账

hr "2. LD_DEBUG=statistics —— 这套流程的账单"

LD_DEBUG=statistics ./ctor-demo 2>&1 | grep -E 'startup time|relocation|load objects|number of relocations' |
    sed 's/^ *[0-9]*: */  /' | head -8

printf '\n  这三个数分开看：\n'
printf '    startup time     链接器自己花的全部时间\n'
printf '    relocation       修正地址（ASLR 让每个进程的基址都不一样，\n'
printf '                     所有写死的绝对地址都得重算一遍）\n'
printf '    load objects     打开并映射各个 .so（这一项占了将近四成）\n'

# ------------------------------------------------------- 3. 符号什么时候绑

hr "3. LD_DEBUG=bindings —— 符号解析，以及它为什么现在几乎看不见"

LD_DEBUG=bindings ./ctor-demo 2>"$WORK/b1.txt" >/dev/null || true
LD_BIND_NOW=1 LD_DEBUG=bindings ./ctor-demo 2>"$WORK/b2.txt" >/dev/null || true
printf '  绑定条数（默认）：       %s\n' "$(grep -c 'binding file.*normal symbol' "$WORK/b1.txt")"
printf '  绑定条数（LD_BIND_NOW=1）：%s\n' "$(grep -c 'binding file.*normal symbol' "$WORK/b2.txt")"
printf '\n  举个绑定长什么样：\n'
LD_DEBUG=bindings ./ctor-demo 2>"$WORK/bind.txt" >/dev/null || true
grep 'binding file.*normal symbol' "$WORK/bind.txt" | head -3 | sed 's/^ *[0-9]*: */    /'

printf '\n  教材里的「PLT 惰性绑定」是怎么回事：\n'
printf '    默认情况下，调用一个外部函数要先跳一小段桩代码（PLT），\n'
printf '    桩代码去查表（GOT），第一次查不到就调链接器解析，然后把结果填回表里。\n'
printf '    所以「第一次调用某个函数」比后面几次贵。\n'

printf '\n  但现在这条基本看不到了 —— 发行版默认加 -z now：\n'
for b in /usr/bin/true /usr/bin/ls; do
    printf '    %-14s JUMP_SLOT 重定位数 = %s，BIND_NOW = %s\n' "$b" \
        "$(readelf -rW "$b" | grep -c 'JUMP_SLOT')" \
        "$(readelf -dW "$b" | grep -c 'BIND_NOW')"
done
printf '    JUMP_SLOT 就是惰性绑定用的那种重定位；0 表示没有惰性可偷\n'
printf '    代价是启动时要多做重定位，换来的是可预测的延迟和完整的 RELRO 保护\n'

# --------------------------------------------------- 4. 亲手造一个惰性绑定

hr "4. 惰性绑定到底「懒」在哪：造一个永不调用的函数"

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

for f in lazy-demo eager-demo; do
    printf '\n  【%s】\n' "$f"
    printf '    DT_FLAGS_1 里有 NOW 吗：%s\n' \
        "$(readelf -dW "$f" | grep -c 'NOW')"
    LD_DEBUG=bindings ./"$f" 2>"$WORK/$f.bind" >/dev/null || true
    printf '    called_sometimes 绑定了几次：%s\n' "$(grep -c 'called_sometimes' "$WORK/$f.bind")"
    printf '    never_called    绑定了几次：%s\n' "$(grep -c 'never_called' "$WORK/$f.bind")"
done

printf '\n  差别就在这里：\n'
printf '    惰性版：never_called 一次都没绑定 —— 链接器压根没去解析它，\n'
printf '            因为那个分支没走过，它的 PLT 桩从没被激活\n'
printf '    全绑版：两个都绑了 —— -z now 让链接器在启动时把 PLT 全部解析完\n'
printf '\n  所以 -z now 不是「删掉 PLT」，是「不再拖到第一次调用才解析」。\n'
printf '  代价是启动更慢，换来的是延迟可预测 + 完整的 RELRO 保护。\n'

# --------------------------------------------------------------- 5. 小结

hr "5. 一句话总结"

cat <<'EOF'
  execve 把控制权交给 ld.so 之后，链接器依次做完四件事：

    找库     读 /etc/ld.so.cache 和各库的 DT_NEEDED，递归找到全部依赖
    映射     把每个 .so 的 PT_LOAD 段 mmap 进来（和 04 里内核做的事同一个套路）
    重定位   把代码和数据里写死的地址，按本次加载的基址重算一遍
    调 init  按依赖顺序调用每个目标文件的初始化函数，主程序排最后

  这四步跟你的程序做了什么**毫无关系** —— 只要你用动态链接，每次启动都要付。
  下一步（06）看怎么把这一整套提前付掉。
EOF
