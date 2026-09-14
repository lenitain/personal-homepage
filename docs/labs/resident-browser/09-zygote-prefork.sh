#!/bin/bash
# 实验：把一个已经把库加载好的进程 fork 出去，比每次都 exec 一个新进程省掉了什么
#
# 动态链接的程序每次启动，都要先跑一遍动态链接器：找库、映射、重定位、调 init
# （第 4 章的 08 把这四步的账打了出来）。这一份看能不能不付第二次。
#
# 做法是自己造一个最小 zygote：父进程把库加载好，之后每个「新任务」用 fork 派生，
# 而不是 exec 一个全新的进程。两条路都派生 N 次，各记两笔账：花了多少毫秒、
# 构造函数跑了几遍。
#
# 再回头看在真实系统里的样子：QtWebEngine / Chromium 的 zygote。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)

cleanup() {
    wait 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cd "$WORK"

N=40      # 两条路各派生多少次

# ------------------------------------------------------------------ 造素材

# 一个「很贵」的库：构造函数里做点可见的事
cat >biglib.c <<'EOF'
#include <stdio.h>
#include <string.h>

static char scratch[8 * 1024 * 1024];   /* 8 MB 数据段，拉开两条路的差距 */

__attribute__((constructor)) static void biglib_init(void) {
    memset(scratch, 1, sizeof scratch);
    fprintf(stderr, "[lib] 构造函数跑了\n");
}

long work(void) {
    long sum = 0;
    for (int i = 0; i < 1000; i++) sum += scratch[i];
    return sum;
}
EOF

# 路线 B 被 exec 的那个程序
cat >worker.c <<'EOF'
#include <stdio.h>
long work(void);
int main(void) {
    printf("%ld\n", work());
    return 0;
}
EOF

# 路线 A：zygote —— 父进程加载一次，之后 fork
cat >zygote.c <<'EOF'
/* 用法: zygote <次数>
 *
 * 父进程先把库用起来（构造函数在父进程里跑掉），之后每个「新任务」都是 fork 出来的
 * 子进程 —— 不 exec，所以子进程继承的是父进程那份已经建好的地址空间。
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
long work(void);
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1;
    work();                       /* 父进程里先把库用起来 */
    if (n > 256) n = 256;
    for (int i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid == 0) { work(); _exit(0); }
        int st; waitpid(pid, &st, 0);
    }
    return 0;
}
EOF

# 路线 B：每次 exec 一个全新的进程
cat >execfresh.c <<'EOF'
/* 用法: execfresh <次数>
 *
 * 每次任务都 fork + exec 一个全新的 ./worker —— 库要从磁盘重新加载一遍。
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1;
    if (n > 256) n = 256;
    for (int i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid == 0) { execl("./worker", "worker", (char *)0); _exit(127); }
        int st; waitpid(pid, &st, 0);
    }
    return 0;
}
EOF

gcc -shared -fPIC -O2 -o libbig.so biglib.c
gcc -O2 -o worker     worker.c   -L. -lbig -Wl,-rpath,"$WORK"
gcc -O2 -o zygote     zygote.c   -L. -lbig -Wl,-rpath,"$WORK"
gcc -O2 -o execfresh  execfresh.c

# ------------------------------------------------------- A 路：fork 继承

start=$(date +%s%N)
./zygote "$N" 2>a.log >/dev/null
end=$(date +%s%N)
a_ms=$(( (end - start) / 1000000 ))
a_init=$(grep -c '构造函数跑了' a.log || true)

# ------------------------------------------------------- B 路：exec 重来

start=$(date +%s%N)
./execfresh "$N" 2>b.log >/dev/null
end=$(date +%s%N)
b_ms=$(( (end - start) / 1000000 ))
b_init=$(grep -c '构造函数跑了' b.log || true)

ratio=$(awk -v a="$a_ms" -v b="$b_ms" 'BEGIN{printf "%.1f", (a > 0 ? b / a : 0)}')

# ---------------------------------------------- 真实的 zygote：它是不是也这样
# 不用 pgrep -x QtWebEngineProcess：内核把 comm 截断到 15 字符（实际是 QtWebEngineProc），
# 按名字匹不上。直接读 /proc，顺便更准确。
qtweb_pids() {
    for d in /proc/[0-9]*; do
        case "$(readlink -f "$d/exe" 2>/dev/null)" in
            */QtWebEngineProcess) echo "${d#/proc/}" ;;
        esac
    done
}
qtweb_of_type() {
    for p in $(qtweb_pids); do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--type=$1"; then
            echo "$p"
        fi
    done
}
so_list() { awk '{print $6}' "/proc/$1/maps" 2>/dev/null | grep '\.so' | sort -u; }

zy=$(qtweb_of_type zygote  | awk 'NR==1')
rd=$(qtweb_of_type renderer | awk 'NR==1')
zy_count=""
rd_extra=""
if [ -n "${zy:-}" ] && [ -n "${rd:-}" ]; then
    zy_count=$(so_list "$zy" | wc -l)
    rd_extra=$(comm -13 <(so_list "$zy") <(so_list "$rd") | wc -l)
fi

# ------------------------------------------------ 一张表（挑出来的原始输出）

cat <<EOF

  这个实验要回答：能不能只付第一次 —— 让一个进程先把库加载好，之后每个新任务从它 fork？

  同一个「贵」库（8 MB 数据段，构造函数里 memset 一遍），同一个任务各做 $N 次：
EOF
printf '  A 路 fork   %s 次任务共花 %4s ms   构造函数跑了 %3s 遍\n' "$N" "$a_ms" "$a_init"
printf '  B 路 exec   %s 次任务共花 %4s ms   构造函数跑了 %3s 遍\n' "$N" "$b_ms" "$b_init"
cat <<EOF

  B 路比 A 路慢 $ratio 倍；多出来的 $(( b_init - a_init )) 遍构造函数，就是动态链接器那四步：
  找库、映射、重定位、调 init（第 4 章的 08 把这笔账打了出来）—— 它们只跟「这份程序映像」有关，
  跟这次任务要干什么毫无关系。fork 不 exec，子进程拿到的是
  父进程那份已经建好的地址空间（写时复制，不真的拷内存），那四步一次都不用再做。
EOF
if [ -n "$rd_extra" ]; then
    if [ "$rd_extra" -eq 0 ]; then
        rd_note="比它多 0 个 —— 一个库都没有重新加载"
    else
        rd_note="比它多 $rd_extra 个"
    fi
    printf '\n  真实系统上 Chromium / QtWebEngine 就是这么干的：zygote 手里 %s 个 .so，\n  renderer 从它 fork 出来，%s。\n' "$zy_count" "$rd_note"
fi
cat <<'EOF'

  这用在哪：这就是「只付一次」本身的做法 —— 但保温的父进程必须*比启动它的东西活得久*，
  常驻的东西总得有人负责它的死（《谁来释放资源》试的就是 PID namespace 这条路）。
EOF
