#!/bin/bash
# 体检：qutebrowser 启动的时候，到底发生了什么
#
# 这一章**还没有任何方案**。qb-server 不存在，也不该出现在这里。
# 体检的对象就是从 shell 里敲的那个普通命令：qutebrowser。
#
# 用的全是第一章讲过的机制，加外部观测工具。不碰任何脚本。
#
#   strace        看 execve 链
#   -X importtime 看 Python 侧的 import 账单
#   readelf/ldd   看它是二进制还是脚本
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note()  { printf '        %s\n' "$1"; }

QB=$(command -v qutebrowser)
[ -n "$QB" ] || { echo "找不到 qutebrowser"; exit 2; }

# ==================================================== 体检 1：它是什么

head_ "体检 1：qutebrowser 是什么"

note "$(file -b "$QB")"
note "$(ls -l "$QB" | awk '{print "大小 " $5 " 字节"}')"
note "头两行："
head -2 "$QB" | sed 's/^/          /'

first_line=$(head -1 "$QB")
case "$first_line" in
    '#!'*python*)
        note ""
        note "→ 它不是二进制，是一个 Python 脚本。"
        note "  shebang 是 $first_line"
        note "  所以 shell 那次 execve 的文件，内核还得再转一手（见体检 2）"
        ;;
    *)  note "→ 它不是一个 Python 脚本，后面按实际情况处理" ;;
esac

# ================================================ 体检 2：execve 链

head_ "体检 2：那次 execve 之后，实际 exec 了什么"

# 用干净的 PATH 跑。不清的话，mise 的 shim 会在 PATH 里层层试探，
# 塞进来几十条跟 qutebrowser 无关的 execve —— 第一次量就被这个骗了。
CLEAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PATH="$CLEAN_PATH" strace -f -e trace=execve -o exec.trace \
    "$QB" --version >/dev/null 2>&1 || true

printf '  真正 exec 成功的程序（去重）：\n'
grep 'execve(' exec.trace | grep '= 0' |
    sed 's/^[0-9]* *execve("\([^"]*\)".*/  \1/' | sort | uniq -c | sort -rn |
    sed 's/^/    /'

total=$(grep -c 'execve(' exec.trace)
failed=$(grep -c 'execve(.*ENOENT' exec.trace)
note ""
note "execve 总共 $total 次，其中 $failed 次是 ENOENT（在 PATH 里找可执行文件没找到）"
note ""
note "⚠️ 这里有个**还没查清**的地方：清掉 PATH 之后 execve 从几十次降到 $total 次，"
note "   但 uname / file / ldconfig 这三个**仍然出现**，而 qutebrowser 自己不该调用它们。"
note "   来源没查明（怀疑还是 shell 环境里的某个钩子）。"
note ""
note "   列出来是因为**测量环境本身就是变量**：第一次不清 PATH 时，trace 里有几十条"
note "   在 mise 的各个 install 目录下试 uname 的记录，全是测量环境的噪声。"
note "   在把这些清干净之前，任何关于「启动花了多少时间」的数字都不可信。"

# ============================================ 体检 3：Python 侧账单

head_ "体检 3：Python 侧的 import 账单"

note "qutebrowser 的入口是 Python，所以先看它 import 了什么。"
note "这只跑到「模块导入完」，Qt 的初始化还没开始 —— 后面那一段见体检 4。"
printf '\n'

PATH="$CLEAN_PATH" timeout 180 python3 -X importtime \
    -c "import qutebrowser.qutebrowser" 2>"$WORK/imp.txt" || true

awk -F'|' 'NF==3 {
        self=$1; cum=$2; name=$3
        gsub(/[^0-9]/,"",self); gsub(/[^0-9]/,"",cum)
        gsub(/^ +| +$/,"",name)
        printf "%s\t%s\t%s\n", cum, self, name
    }' "$WORK/imp.txt" | sort -rn > imp.tsv

printf '  累计耗时最长的 12 项：\n'
head -12 imp.tsv | while IFS=$'\t' read -r cum self name; do
    printf '    %8.1f ms  (自身 %6.1f ms)  %s\n' \
        "$(awk -v v="$cum" 'BEGIN{print v/1000}')" \
        "$(awk -v v="$self" 'BEGIN{print v/1000}')" "$name"
done

printf '\n'
total_import=$(grep -c . imp.tsv)
top=$(head -1 imp.tsv | cut -f1)
printf '  总共 import 了 %s 个模块\n' "$total_import"
printf '  最外层那一项（qutebrowser.qutebrowser）的累计耗时：%.0f ms\n' \
    "$(awk -v v="$top" 'BEGIN{print v/1000}')"

# ================================================ 还没量到的

head_ "体检到此为止 —— 还有一大段没量"

cat <<'EOF'
  上面三步量到的，只是「解释器起来 + 模块导入完」这一段。
  而 qutebrowser 从敲下命令到窗口出现要 1.2 秒，中间还有：

    · Qt 的初始化（PyQt6 是在 main() 里才 import 的，不在上面那份账单里）
    · QtWebEngine 的初始化 —— 体检 2 里已经看到，它连 --version 都会起 zygote
    · adblock 规则解析
    · profile 装载
    · 窗口创建

  这几段要接着量。量出来之后才谈得上「哪几段是每次完全一样的」——
  而那正是下一章要回答的问题。

  现在下任何关于「能不能拆开」的结论都太早：我们才刚看清这条链有几节。
EOF
