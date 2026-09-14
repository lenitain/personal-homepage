#!/bin/bash
# 体检：qutebrowser 启动的时候，到底发生了什么
#
# 这一章还没有任何方案。体检的对象就是从 shell 里敲的那个普通命令：qutebrowser。
#
# 四段，一节回答一个问题：
#
#   1  file / 头两行     它是二进制还是脚本（这个答案决定了后面两段怎么读）
#   2  strace -f         execve 链：这条命令跑下去，真正 exec 成功的都有谁
#   3  -X importtime     Python 侧的 import 账单：哪些模块贵，贵在哪儿
#   4  strace -f -tt     把启动全程放回时间线上，取三个外部可观测的界标，
#                        算出 Python 段和 Qt 段各多少毫秒
#
# 哪几个细节不做，就什么都看不出来：
#
#   一、strace 必须清掉 PATH。不清的话，mise 的 shim 会在 PATH 里层层试探，
#      塞进来几十条跟 qutebrowser 无关的 execve —— 那份 trace 里既有 qutebrowser
#      的行为，也有测量环境的噪声，而且分不开。清干净之后「execve 链」这个词才有意义。
#   二、strace 必须带 -f。qutebrowser 是 Python 脚本，execve 链是一条
#      （shell → qutebrowser 脚本 → python3 → …），不跟子进程就只剩第一跳。
#   三、importtime 必须 import 真正的入口 qutebrowser.qutebrowser，不是顶层包 qutebrowser ——
#      顶层包几乎不 import 东西，跑出来会是一份空账单。
#   四、这段账单只到「模块导入完」为止。Qt 是在 main() 里才 import 的，不在这份账单里；
#      所以要另起一段带时间戳的 trace，用「第一个 libQt6*.so 被打开」当 Python 段的终点。
#      界标必须选外部能看见的（execve / openat / connect），不能靠打印自己的时间。
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
# 体检 4 会真的把 qutebrowser 启起来（窗口一闪），收尾时连整组一起杀干净
pgroup=""
cleanup() {
    [[ -n "$pgroup" ]] && kill -KILL -- "-$pgroup" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
cd "$WORK"

CLEAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
QB=$(PATH="$CLEAN_PATH" command -v qutebrowser)
[ -n "$QB" ] || { echo "找不到 qutebrowser"; exit 2; }

# ==================================================== 体检 1：它是什么

kind=$(file -b "$QB")
size=$(stat -c%s "$QB")
first_line=$(head -1 "$QB")
case "$first_line" in
    '#!'*python*) qb_kind="Python 脚本" ;;
    '#!'*)        qb_kind="脚本（shebang: $first_line）" ;;
    *)            qb_kind="不是脚本（$kind）" ;;
esac

# ================================================ 体检 2：execve 链

# 连带的一整组一起收：--version 也会起 QtWebEngine 的 zygote，它比父进程活得久
PATH="$CLEAN_PATH" setsid timeout 60 strace -f -e trace=execve -o exec.trace \
    "$QB" --version >/dev/null 2>&1 &
pgroup=$!
wait "$pgroup" 2>/dev/null || true
kill -KILL -- "-$pgroup" 2>/dev/null || true
pgroup=""

total=$(grep -c 'execve(' exec.trace)
failed=$(grep -c 'execve(.*ENOENT' exec.trace)
execd=$(grep 'execve(' exec.trace | grep -c '= 0')
# 真正 exec 成功的程序，去重后按次数排；只留 basename，一行放得下
exec_list=$(grep 'execve(' exec.trace | grep '= 0' |
    sed 's/^[0-9]* *execve("\([^"]*\)".*/\1/' | sort | uniq -c | sort -rn |
    awk '{n=$1; sub(/^ *[0-9]+ +/, ""); sub(/.*\//, "");
          printf "%s%s", (NR>1 ? "、" : ""), (n>1 ? $0" ×"n : $0)}')

# ============================================ 体检 3：Python 侧账单

PATH="$CLEAN_PATH" timeout 180 python3 -X importtime \
    -c "import qutebrowser.qutebrowser" 2>"$WORK/imp.txt" || true

awk -F'|' 'NF==3 {
        self=$1; cum=$2; name=$3
        gsub(/[^0-9]/,"",self); gsub(/[^0-9]/,"",cum)
        gsub(/^ +| +$/,"",name)
        printf "%s\t%s\t%s\n", cum, self, name
    }' "$WORK/imp.txt" | sort -rn > imp.tsv

total_import=$(grep -c . imp.tsv)
top=$(head -1 imp.tsv | cut -f1)
top_ms=$(awk -v v="$top" 'BEGIN{printf "%.0f", v/1000}')
self_top=$(sort -k2 -rn imp.tsv | head -1)
self_name=$(printf '%s' "$self_top" | cut -f3)
self_ms=$(printf '%s' "$self_top" | cut -f2 | awk '{printf "%.1f", $1/1000}')

# ============================================ 体检 4：把 1.2 秒切成两段

# 全程带时间戳。f 跟子进程，tt 打时刻；界标全从 trace 里挑，脚本自己不插桩。
# 用 setsid 起一整组，跑完连 strace 带 qutebrowser 一起杀，不留残留进程。
setsid timeout 60 strace -f -tt -o trace.txt \
    "$QB" -R about:blank >/dev/null 2>&1 &
pgroup=$!
for _ in $(seq 1 600); do
    grep -qE 'connect\(.*wayland-[0-9]+".* = 0' trace.txt 2>/dev/null && break
    sleep 0.1
done
sleep 0.5
kill -KILL -- "-$pgroup" 2>/dev/null || true
wait "$pgroup" 2>/dev/null || true
pgroup=""

# 时刻形如 09:20:43.188392（-tt 给的是微秒）→ 毫秒。10# 是防止 09 被当八进制。
to_ms() {
    local t="$1" hms=${1%.*} frac=${1##*.}
    local h=${hms%%:*} rest=${hms#*:}
    local m=${rest%%:*} s=${rest#*:}
    printf '%d' $(( (10#$h * 3600 + 10#$m * 60 + 10#$s) * 1000 + 10#${frac:0:3} ))
}

ts_start=$(awk '/execve\(/{print $2; exit}' trace.txt)
ts_start=${ts_start:-00:00:00.000000}
ts_qt=$(grep -m1 -E 'openat\(.*libQt6[^"]*\.so[^"]*".* = [0-9]+' trace.txt | awk '{print $2}')
ts_wl=$(grep -m1 -E 'connect\(.*wayland-[0-9]+".* = 0' trace.txt | awk '{print $2}')
ts_qt=${ts_qt:-$ts_start}
ts_wl=${ts_wl:-$ts_qt}
qt_so=$(grep -m1 -E 'openat\(.*/libQt6[^"]*\.so[^"]*"' trace.txt | sed 's/.*"\([^"]*\)".*/\1/')
qt_so=${qt_so##*/}

py_ms=$(( $(to_ms "$ts_qt") - $(to_ms "$ts_start") ))
qt_ms=$(( $(to_ms "$ts_wl") - $(to_ms "$ts_qt") ))

# 三个界标各一行：时刻 + 相对起点多少毫秒 + 事件。相对那一列是 ASCII，对齐没问题。
marks=$(printf '    %s  %8s  %s\n' "$ts_start" "0 ms" "execve(\"$QB\") —— 起点"
        printf '    %s  %8s  第一个 %s 被打开 —— Python 阶段结束\n' "$ts_qt" "+$py_ms ms" "$qt_so"
        printf '    %s  %8s  第一次 connect 到 wayland —— 窗口要出现了\n' "$ts_wl" "+$(( py_ms + qt_ms )) ms")

cat <<EOF

  这个实验要回答：从敲下 qutebrowser 到窗口出现的那 1.2 秒，花在哪几段？

  它是什么     $qb_kind，$size 字节，头一行 $first_line
  execve 链    真正 exec 成功 $execd 次：$exec_list
               execve 共 $total 次，其中 $failed 次是 ENOENT（在 PATH 里找可执行文件没找到）
  import 账单  $total_import 个模块，最外层累计 $top_ms ms；自身最贵的是 $self_name（$self_ms ms，跟浏览器无关）

  给启动全程打时间戳（strace -f -tt $QB -R about:blank），三个外部可观测的界标：
$marks

  于是这 1.2 秒分成两段：*前 $py_ms 毫秒是 Python*（跟体检 3 的 $top_ms ms 账单对得上），
  *后 $qt_ms 毫秒是 Qt 和 QtWebEngine*，大头在这一段。

  这用在哪：先把 1.2 秒切成两半，才谈得上问「哪一半是每次完全一样的」——
  而「能不能只付一次」问的就是它。
EOF
