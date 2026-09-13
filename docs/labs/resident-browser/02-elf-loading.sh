#!/bin/bash
# 验证：可执行文件是怎么变成进程地址空间的
#
# 这个脚本**不讲课**。它只做一件事：把第一章里那几句断言，一条条拿到这台机器上查。
# 每条检查都从真实观测里算出来，通过就 PASS，不通过就 FAIL 并退出非零。
#
# 被验证的断言：
#   A. 静态链接的文件没有 PT_INTERP，动态链接的有
#   B. 每个 PT_LOAD 段都能在进程地址空间里找到对应的映射（地址 + 权限）
#   C. 动态链接的程序，exec 之后第一条指令落在 ld.so 里，不在主程序里
#   D. 静态链接的程序，第一条指令落在主程序自己里
#   E. 链接器给 libc 发的 mmap 次数 = libc 的 PT_LOAD 段数
#
# 其中 C/D 用 tools/execprobe.c：让内核在 exec 刚做完、第一条指令还没执行时
# 把进程停住，直接读 RIP。这是唯一能验证「内核跳转的是解释器」的办法 ——
# strace 看不到，因为内核在 execve 内部做的事不产生新的系统调用记录。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()    { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note()  { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cc -O2 -o execprobe "$ROOT/tools/execprobe.c" 2>/dev/null || { echo "编译 execprobe 失败"; exit 2; }

# ------------------------------------------------------------------ 素材

# 关键：**同一个二进制**既要提供段表、又要提供地址空间。
# 一开始我图省事，另写了一个 mapsdump 程序去 dump 地址空间 ——
# 那是另一个二进制，段表完全不同，检查自然对不上。
cat >hello.c <<'EOF'
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "maps") == 0) {
        char line[1024];
        FILE *f = fopen("/proc/self/maps", "r");
        while (f && fgets(line, sizeof line, f)) fputs(line, stdout);
        return 0;
    }
    puts("hi");
    return 0;
}
EOF

cc -O2 -o hello-dyn hello.c
cc -O2 -static -o hello-static hello.c 2>/dev/null || musl-gcc -O2 -static -o hello-static hello.c

# ==================================================================== A

head_ "断言 A：静态链接的文件没有 PT_INTERP，动态链接的有"

has_interp() { readelf -lW "$1" | grep -q 'INTERP'; }
has_interp hello-static && bad "hello-static 不该有 PT_INTERP" || ok "hello-static 没有 PT_INTERP"
has_interp hello-dyn    && ok  "hello-dyn 有 PT_INTERP"          || bad "hello-dyn 应该有 PT_INTERP"
note "hello-dyn 请求的解释器：$(readelf -lW hello-dyn | grep -oP '(?<=program interpreter: ).*(?=\])')"

# ==================================================================== B

head_ "断言 B：每个 PT_LOAD 段都在地址空间里有对应映射"

# 把 readelf 的段表和 maps 对齐。三个坑，都是写这个检查时才发现的：
#
#   1. 权限列 "R E" 中间有空格，不能只取一个字段
#   2. PT_LOAD 的地址不必页对齐（.data 紧跟在 .rodata 后面），
#      而内核映射时一定按页对齐 —— 比较前要先向下取整到页
#   3. PIE 程序（现在默认都是）段表里的地址是**相对基址**的，
#      实际映射在随机基址上 —— 得先从 maps 里把这个基址算出来
check_loads() {
    local prog="$1" maps="$2"
    local abs; abs=$(readlink -f "$prog")
    local total=0 matched=0

    # PT_LOAD 列表：vaddr memsz 权限
    local loads
    loads=$(readelf -lW "$prog" | awk '
        $1=="LOAD" {
            flg = $7
            if ($8 == "E") flg = "R E"
            print $3, $6, flg
        }')

    # 加载基址 = 程序在 maps 里的第一个映射起点 − 第一个 PT_LOAD 的 vaddr
    local first_vaddr first_map bias
    first_vaddr=$(printf '%s\n' "$loads" | awk 'NR==1{print $1}')
    first_map=$(awk -v p="$abs" 'index($0, p) {print $1; exit}' "$maps" | cut -d- -f1)
    # 注意：readelf 打印的地址本来就带 0x 前缀，不能再加一个
    bias=$(awk -v v="$first_vaddr" -v m="0x$first_map" 'BEGIN{printf "%d", strtonum(m) - strtonum(v)}')

    local vaddr memsiz flg
    while read -r vaddr memsiz flg; do
        [ -n "$vaddr" ] || continue
        total=$((total+1))

        local want
        case "$flg" in
            "R")    want="r--" ;;
            "R E")  want="r-x" ;;
            "RW")   want="rw-" ;;
            *)      want="?" ;;
        esac

        # 期望覆盖的区间：基址 + [vaddr, vaddr+memsiz)，两端都向下取整到页
        #
        # 这里**不能要求起始地址相等**。PT_LOAD 的文件偏移不一定是页对齐的，
        # 这时内核会把前导的半个页单独映射成只读（它跟前面那个只读段共用一个页），
        # 可写部分从下一个页边界才开始 —— 于是 maps 里出现两行。
        # 所以判定用「区间有重叠 + 权限相符」。
        read -r want_lo want_hi < <(awk -v v="$vaddr" -v m="$memsiz" -v b="$bias" '
            BEGIN {
                lo = strtonum(v) + b
                hi = strtonum(v) + strtonum(m) + b
                # lo 向下取整、hi 向上取整：小段的 lo/hi 若都向下取整会得到同一个值，
                # 区间变空，检查必然失败
                printf "%x %x\n", int(lo / 4096) * 4096, int((hi + 4095) / 4096) * 4096
            }')

        local hit
        hit=$(awk -v lo="$want_lo" -v hi="$want_hi" -v want="$want" '
            {
                split($1, r, "-")
                a = strtonum("0x" r[1]); b = strtonum("0x" r[2])
                if (a < strtonum("0x" hi) && b > strtonum("0x" lo) && substr($2,1,3) == want) {
                    print $1" "$2; exit
                }
            }' "$maps")

        if [ -n "$hit" ]; then
            matched=$((matched+1))
            note "PT_LOAD @$vaddr..+$memsiz [$want] 期望落在 $want_lo..$want_hi → $hit" >&2
        else
            note "PT_LOAD @$vaddr..+$memsiz [$want] 期望落在 $want_lo..$want_hi → 找不到" >&2
        fi
    done <<< "$loads"

    printf '%s %s\n' "$matched" "$total"
}

for prog in hello-static hello-dyn; do
    ./"$prog" maps > "$prog.maps"
    read -r m t < <(check_loads "$prog" "$prog.maps")
    printf '\n'
    if [ "$m" -eq "$t" ] && [ "$t" -gt 0 ]; then
        ok "$prog：$t 个 PT_LOAD 全部找到对应映射"
    else
        bad "$prog：只有 $m/$t 个 PT_LOAD 找到对应映射"
    fi
done

# ==================================================================== C / D

head_ "断言 C / D：exec 之后第一条指令落在哪"

./execprobe ./hello-static > entry-static.txt 2>&1
./execprobe ./hello-dyn    > entry-dyn.txt    2>&1

for f in entry-static.txt:hello-static entry-dyn.txt:hello-dyn; do
    file="${f%%:*}"; label="${f##*:}"
    rip=$(awk -F'\t' '$1=="entry_rip"{sub(/^0x/,"",$2); print $2}' "$file")
    where=$(awk -F'\t' '$1=="entry_file"{print $2}' "$file")
    printf '\n  %s\n    ript = 0x%s\n    落在 = %s\n' "$label" "$rip" "$where"
done
printf '\n'

static_file=$(awk -F'\t' '$1=="entry_file"{print $2}' entry-static.txt)
dyn_file=$(awk -F'\t' '$1=="entry_file"{print $2}' entry-dyn.txt)
dyn_self=$(awk -F'\t' '$1=="self_mapped"{print $2}' entry-dyn.txt)

case "$static_file" in
    *hello-static)        ok "静态：第一条指令在主程序自己里面" ;;
    *)                    bad "静态：第一条指令居然在 $static_file" ;;
esac

case "$dyn_file" in
    *ld-linux*|*ld-musl*) ok "动态：第一条指令在解释器里（$dyn_file）" ;;
    *)                    bad "动态：第一条指令在 $dyn_file，不是解释器" ;;
esac

if [ "$dyn_self" = "1" ]; then
    ok "动态：主程序本身也被映射进来了，只是不从它开始跑"
else
    bad "动态：主程序没有被映射，跟预期不符"
fi

# ==================================================================== E

head_ "断言 E：链接器给 libc 发的 mmap 次数 = libc 的 PT_LOAD 段数"

libc=$(ldd hello-dyn | awk '/libc\.so/{print $3}')
libc_loads=$(readelf -lW "$libc" | grep -c '^  LOAD')

strace -f -o trace.txt ./hello-dyn >/dev/null 2>&1

# 注意：不能只按 fd 数。fd 会被复用 —— ld.so.cache 也用 fd 3，
# 打开读完就关掉，然后 libc 又拿到 3。所以必须只数「libc 那次 openat 之后」的 mmap。
read -r libc_fd libc_mmaps <<<"$(awk -v libc="$libc" '
    index($0, "openat(") && index($0, "\"" libc "\"") && !opened {
        if (match($0, /= [0-9]+$/)) { fd = substr($0, RSTART+2); opened = 1 }
        next
    }
    opened && index($0, "mmap(") {
        # 该行的 fd 参数形如 ", <fd>, "
        if (index($0, ", " fd ", ")) n++
    }
    END { printf "%s %d\n", fd, n }
' trace.txt)"

note "libc = $libc"
note "readelf 数出的 PT_LOAD 段数 = $libc_loads"
note "strace 里对该 fd 的 mmap 次数 = $libc_mmaps（fd=$libc_fd）"

if [ "$libc_loads" -eq "$libc_mmaps" ] && [ "$libc_loads" -gt 0 ]; then
    ok "两者相等（$libc_loads）—— 链接器确实按段表逐段映射"
else
    bad "两者不等（段表 $libc_loads，mmap $libc_mmaps）"
fi

printf '\n  strace 里那几行（同一个 fd、MAP_FIXED）：\n'
grep -P "mmap\(.*, $libc_fd, " trace.txt | sed 's/^[0-9]* *//' | head -6 | sed 's/^/    /'

# ================================================================== 汇总

printf '\n\033[1m结果：%d 条通过，%d 条失败\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
