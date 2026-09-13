#!/bin/bash
# 演示：什么样的加载开销可以「提前付掉」
#
# 承接 05 —— 找库、映射、重定位、调 init 这四步跟你的程序无关，每次启动都要付。
# 这一份看能不能不付第二次。
#
# 做法是自己造一个最小 zygote：父进程把库加载好，之后每个「新任务」用 fork 派生，
# 而不是 exec 一个全新的进程。两条路各跑 N 次，数构造函数跑了几遍、各花多少时间。
#
# 再回头看在真实系统里的样子：QtWebEngine / Chromium 的 zygote。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

hr() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

N=40

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

cat >worker.c <<'EOF'
#include <stdio.h>
long work(void);
int main(void) { printf("%ld\n", work()); return 0; }
EOF

# 路线 A：zygote —— 父进程加载一次，之后 fork
cat >zygote.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
long work(void);
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1;
    work();                       /* 父进程里先把库用起来 */
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
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1;
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

# ------------------------------------------------------- A/B：各派生 40 次

hr "A）zygote：父进程加载一次，之后全靠 fork（各派生 $N 次）"

start=$(date +%s%N)
./zygote "$N" 2>"$WORK/a.log" >/dev/null
end=$(date +%s%N)
a_ms=$(( (end - start) / 1000000 ))
a_init=$(grep -c '构造函数跑了' "$WORK/a.log" || true)
printf '  构造函数跑了几遍: %s\n' "$a_init"
printf '  总耗时:           %s ms\n' "$a_ms"

hr "B）exec：每次 exec 一个全新进程（各派生 $N 次）"

start=$(date +%s%N)
./execfresh "$N" 2>"$WORK/b.log" >/dev/null
end=$(date +%s%N)
b_ms=$(( (end - start) / 1000000 ))
b_init=$(grep -c '构造函数跑了' "$WORK/b.log" || true)
printf '  构造函数跑了几遍: %s\n' "$b_init"
printf '  总耗时:           %s ms\n' "$b_ms"

hr "对比"

printf '  fork 继承：初始化 %s 次，%s ms\n' "$a_init" "$a_ms"
printf '  exec 重来：初始化 %s 次，%s ms\n' "$b_init" "$b_ms"
printf '  差距约 %s 倍\n' "$(awk -v a="$a_ms" -v b="$b_ms" 'BEGIN{printf "%.1f", b/a}')"

printf '\n  为什么 fork 不用重新加载：\n'
printf '    fork 出来的子进程拿到的是一份**已经建好的地址空间**的副本\n'
printf '    （内核用写时复制，所以并不真的拷内存）\n'
printf '    库的映射、重定位的结果、构造函数跑完的状态，全都在里面\n'
printf '    —— 05 里那四步，一次都不用再做\n'

# ---------------------------------------------- 真实的 zygote 长什么样

hr "真实的 zygote：QtWebEngine / Chromium 就是这么干的"

# 不用 pgrep -x QtWebEngineProcess：内核把 comm 截断到 15 字符
# （实际是 QtWebEngineProc），按名字匹不上。直接读 /proc，顺便更准确。
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

if [ -n "$(qtweb_pids)" ]; then
    printf '  当前系统上的 QtWebEngine 进程（pid / 父进程 / 类型）：\n'
    for p in $(qtweb_pids); do
        t=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null |
            grep -oE -- '--type=[a-z]+' | head -1 | cut -d= -f2)
        printf '    %-8s %-8s %s\n' "$p" "$(awk '{print $4}' "/proc/$p/stat")" "${t:-（无）}"
    done

    # 先收进变量，不要直接接 head —— 循环里的 echo 会撞上 SIGPIPE
    zy_all=$(qtweb_of_type zygote);  ZY=$(printf '%s\n' "$zy_all" | head -1)
    rd_all=$(qtweb_of_type renderer); RD=$(printf '%s\n' "$rd_all" | head -1)

    if [ -n "$ZY" ] && [ -n "$RD" ]; then
        printf '\n  renderer(pid %s) 的父进程 = %s\n' "$RD" "$(awk '{print $4}' "/proc/$RD/stat")"
        printf '  两者映射的共享库列表是否一致：'
        if diff -q <(awk '{print $6}' "/proc/$ZY/maps" 2>/dev/null | grep '\.so' | sort -u) \
                   <(awk '{print $6}' "/proc/$RD/maps" 2>/dev/null | grep '\.so' | sort -u) >/dev/null; then
            printf '完全一致 —— renderer 一个共享库都没自己加载\n'
        else
            printf '有差异\n'
        fi
        printf '    zygote   : %s 个 VMA，RSS %s kB\n' \
            "$(wc -l < "/proc/$ZY/maps" 2>/dev/null)" \
            "$(awk '/^Rss:/{print $2}' "/proc/$ZY/smaps_rollup" 2>/dev/null)"
        printf '    renderer : %s 个 VMA，RSS %s kB\n' \
            "$(wc -l < "/proc/$RD/maps" 2>/dev/null)" \
            "$(awk '/^Rss:/{print $2}' "/proc/$RD/smaps_rollup" 2>/dev/null)"
        printf '    （renderer 多出来的是它跑起来之后的堆和 JIT 代码，\n'
        printf '      不是加载新库 —— 库是从 zygote 继承的）\n'
    fi
else
    printf '  （现在没有 QtWebEngine 在跑，跳过。启动 qutebrowser 后再跑一次）\n'
fi

# --------------------------------------------------------------- 小结

hr "小结：判断标准"

cat <<'EOF'
  一个开销能不能提前付，看的是同一件事：

    有没有一条**进程边界**，让贵的那部分跨多次使用共享？

  QtWebEngine 有：引擎的状态跟「你打开哪个网页」无关，所以它可以活在一个
  单独的进程里，每个新标签页只需从它 fork 一下。
  zygote 就是这个「共享的那一份」的载体。

  反过来说，如果每次要用的东西都必须跟这次请求绑定、没法共享，
  那就没有可提前付的部分 —— 这正好接回「什么样的程序值得常驻」那个判据。
EOF
