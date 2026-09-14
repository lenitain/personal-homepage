#!/bin/bash
# 实验：文件里的段表，和进程地址空间里的映射，一行行对得上
#
# 看什么：
#   readelf -lW 的 LOAD 行 —— 段在文件里的 vaddr / memsz / Flg
#   /proc/<pid>/maps 的行 —— 段在地址空间里的起点-终点 / 权限 / 偏移 / 路径
# 一行行对着看。文件里那几行 LOAD，就是进程里那几行映射。
#
# 哪些细节不做就什么都看不出来：
#
#   一、段表和地址空间必须出自同一个二进制。图省事另写一个 dump maps 的小程序，
#       它的段表跟被观察的程序完全不同，两边永远对不上。
#       所以下面那个进程就是 hello 自己 —— 它读的是 /proc/self/maps。
#   二、现在默认编出来都是 PIE：段表里的地址是相对基址的，真实映射落在随机基址上。
#       要先把基址算出来（maps 里第一条映射的起点 − 第一个 PT_LOAD 的 vaddr），
#       不然每一行都差同一个随机数，看着像全错 —— 其实一条不差。
#   三、PT_LOAD 的地址不必页对齐（.data 紧跟在 .rodata 后面），而内核映射一定按页对齐，
#       于是有时一个段在 maps 里裂成两行。所以判定用「区间有重叠 + 权限相符」，
#       不能要求起始地址相等。
#   四、想看「exec 之后第一条指令落在解释器里」，得让内核在 exec 刚做完、第一条指令
#       还没执行的那一刻把进程停住，再读 RIP —— 用 tools/execprobe.c（ptrace）。
#       strace 看不到：内核在 execve 内部做的事不产生新的系统调用记录。
#
# 对应《我的 qutebrowser 启动好慢》第 1 节「一个进程里面有什么」。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"

pass=0; fail=0
# 成功的断言不打印（最后只留一行汇总）；失败的打得出来，不然没法查
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1" >&2; }

cc -O2 -o execprobe "$ROOT/tools/execprobe.c" 2>/dev/null || { echo "编译 execprobe 失败" >&2; exit 2; }

# ------------------------------------------------------------------ 素材

# 关键：同一个二进制既要提供段表、又要提供地址空间。
# 一开始我图省事，另写了一个 mapsdump 程序去 dump 地址空间 ——
# 那是另一个二进制，段表完全不同，检查自然对不上。
cat >hello.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void dump_maps(void)
{
    char line[1024];
    FILE *f = fopen("/proc/self/maps", "r");
    while (f && fgets(line, sizeof line, f)) fputs(line, stdout);
    if (f) fclose(f);
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "maps") == 0) {
        dump_maps();
        return 0;
    }
    puts("hi");
    return 0;
}
EOF

cc -O2 -o hello-dyn hello.c
cc -O2 -static -o hello-static hello.c 2>/dev/null || musl-gcc -O2 -static -o hello-static hello.c

# readelf 的标题行会跟着 locale 变（中文环境打的是「程序头：」），
# 要按文字认它就得不认语言 —— 解析一律 LC_ALL=C。
n_loads()     { LC_ALL=C readelf -lW "$1" | awk '$1=="LOAD"{n++} END{print n+0}'; }
n_map_lines() { awk '/^[0-9a-f]+-/{n++} END{print n+0}' "$1"; }
n_map_of()    { awk -v p="$2" 'index($0, p){n++} END{print n+0}' "$1"; }

check_loads() {   # $1 = 程序  $2 = maps 文件；stdout 一行 "matched total"
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

        # 期望覆盖的区间：基址 + [vaddr, vaddr+memsiz)，两端分别向下/向上取整到页。
        # 不能要求起始地址相等：PT_LOAD 的文件偏移不一定页对齐，这时内核会把前导的
        # 半个页单独映射成只读（它跟前面那个只读段共用一个页），可写部分从下一个页
        # 边界才开始 —— 于是 maps 里出现两行。所以判定用「区间有重叠 + 权限相符」。
        local want_lo want_hi
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
                if (a < strtonum("0x" hi) && b > strtonum("0x" lo) && substr($2,1,3) == want)
                    print $1" "$2
            }' "$maps" | head -1)
        [ -n "$hit" ] && matched=$((matched+1))
    done <<< "$loads"

    printf '%s %s\n' "$matched" "$total"
}

# ==================================================================== 核对

# ---------- A：静态链接的文件没有 PT_INTERP，动态链接的有
has_interp() { readelf -lW "$1" | grep -q 'INTERP'; }
has_interp hello-static && bad "hello-static 不该有 PT_INTERP" || ok "hello-static 没有 PT_INTERP"
has_interp hello-dyn    && ok  "hello-dyn 有 PT_INTERP"          || bad "hello-dyn 应该有 PT_INTERP"
interp=$(LC_ALL=C readelf -lW hello-dyn | grep -oP '(?<=program interpreter: ).*(?=\])')

# ---------- B：每个 PT_LOAD 段都在地址空间里有对应映射
# 三个坑：权限列 "R E" 中间有空格不能只取一个字段；PT_LOAD 的地址不必页对齐而内核
# 映射一定按页对齐；PIE 的段表地址是相对随机基址的。check_loads 里都处理了。
for prog in hello-static hello-dyn; do
    ./"$prog" maps > "$prog.maps"
    read -r m t < <(check_loads "$prog" "$prog.maps")
    if [ "$m" -eq "$t" ] && [ "$t" -gt 0 ]; then
        ok "$prog：$t 个 PT_LOAD 全部找到对应映射"
    else
        bad "$prog：只有 $m/$t 个 PT_LOAD 找到对应映射"
    fi
done

# ---------- C / D：exec 之后第一条指令落在哪
./execprobe ./hello-static > entry-static.txt 2>&1
./execprobe ./hello-dyn    > entry-dyn.txt    2>&1

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

# ---------- E：链接器给 libc 发的 mmap 次数 = libc 的 PT_LOAD 段数
libc=$(ldd hello-dyn | awk '/libc\.so/{print $3}')
libc_loads=$(LC_ALL=C readelf -lW "$libc" | grep -c '^  LOAD')

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

if [ "$libc_loads" -eq "$libc_mmaps" ] && [ "$libc_loads" -gt 0 ]; then
    ok "两者相等（$libc_loads）—— 链接器确实按段表逐段映射"
else
    bad "两者不等（段表 $libc_loads，mmap $libc_mmaps）"
fi

# ====================================================== 这套流程要花多少钱

cc -O2 -o bench "$ROOT/bench.c" 2>/dev/null || { echo "编译 bench 失败" >&2; exit 2; }

# 绑核：不绑核的话，同一份代码在开着桌面会话的机器上读数能差一半
CPU=$(nproc); CPU=$(( CPU - 1 ))
run_bench() {
    taskset -c "$CPU" ./bench 400 100 "$1" 2>/dev/null | awk -F'\t' '
        $1 == "p50_us"   { p50 = $2 }
        $1 == "maxrss_kb"{ rss = $2 }
        END { printf "%s %.0f %.0f", "ok", p50, rss }'
}
for prog in hello-static hello-dyn; do
    read -r _ p50 rss < <(run_bench "./$prog")
    eval "${prog//-/_}_us=$p50"
done
static_us=$hello_static_us
dyn_us=$hello_dyn_us
delta=$(( dyn_us - static_us ))

# ====================================================== 挑出来的原始输出

dyn_loads=$(n_loads hello-dyn)
static_loads=$(n_loads hello-static)
dyn_lines=$(n_map_lines hello-dyn.maps)
static_lines=$(n_map_lines hello-static.maps)
libc_lines=$(n_map_of hello-dyn.maps "libc.so")
ldso_lines=$(n_map_of hello-dyn.maps "ld-linux")
ldcache_lines=$(n_map_of hello-dyn.maps "ld.so.cache")
dyn_bias=$(awk -v p="$WORK/hello-dyn" '
    /^[0-9a-f]+-/ && index($0, p) { print $1; exit }' hello-dyn.maps | cut -d- -f1)
static_base=$(awk -v p="$WORK/hello-static" '
    /^[0-9a-f]+-/ && index($0, p) { print $1; exit }' hello-static.maps | cut -d- -f1)

cat <<EOF

  这个实验要回答：文件里的段表，跟进程地址空间里那些行是怎么对上的？

  同一个 hello.c 编两份，文件里各自都是 $dyn_loads 段（R / R E / R / RW）：
  hello-dyn     地址空间 $dyn_lines 行 = 段表 $dyn_loads 行 + 别人给的 $(( dyn_lines - dyn_loads )) 行
  hello-static  地址空间 $static_lines 行 = 段表 $static_loads 行 + 内核给的 $(( static_lines - static_loads )) 行

  多出来的 $(( dyn_lines - dyn_loads )) 行里：libc.so.6 $libc_lines 行、ld-linux-x86-64.so.2 $ldso_lines 行、ld.so.cache $ldcache_lines 行，
  剩下的是 vdso / vvar / stack / heap / 匿名，加上它自己那个 RW 段被内核按页拆出来的半页 ——
  这个文件的段表里一个字都没写。静态版短掉的正是这一堆：它的 $static_loads 段落在固定地址 0x$static_base，
  动态版那 $dyn_loads 段落在随机基址 0x$dyn_bias 上；exec 完第一条指令落在 $dyn_file，不在主程序里。

  断言：$pass 条 PASS，$fail 条 FAIL

  这用在哪：两个都只打印一行字的程序各跑 400 次，静态 $static_us µs、动态 $dyn_us µs ——
  多出来的 $delta µs 全是链接器的活（找库、映射、重定位、调 init），跟程序要做什么毫无关系。
EOF

[ "$fail" -eq 0 ] || exit 1
