#!/bin/bash
# overflow-check.sh — 探 C 版启动器缓冲区溢出的边界
#
# 输出是一张扫描表：同一个启动器，参数长度从 8000 走到 8300，盯三件事：
#
#   bytes_sent     假 socket 收到了多少字节 —— 快路径还通不通
#   rc             进程退出码 —— 它是正常退出，还是根本没干成
#   fallback_trace strace 里那条 fallback 的 execve —— 它改去哪儿了
#
# 出事的那个长度不报错、不打日志、退出码也可能照样是 0。它只是悄悄换了行为。
# 三列必须一起看才看得出来：只看 rc，你分不出「快路径直发成功」和
# 「fallback 干净地冷启动了一个别人」。
#
# 哪几个细节不做，就什么都看不出来：
#
#   一、绝不能直接跑那个二进制。越界写出来的字节要是恰好构成一个合法的指针数组，
#      execve 是能成功的 —— 那就真的会拉起用户的浏览器。所以整个实验跑在私有
#      mount namespace 里，并且把 /bin/true 绑到 /usr/bin/qutebrowser 上：
#      fallback 真触发时，exec 的是 coreutils 的 true，不是浏览器。
#      不要绕过这层 —— 这个安全网是 bug 的失败模式决定的，不是谨慎。
#   二、假 socket 必须先就绪再开始。没有它，启动器连不上 socket 就直接走 fallback，
#      你量到的是「启动一个浏览器」，而不是「快路径发不出去」。
#   三、每个长度都要单独 strace 一次。这个 bug 的失败模式是「静默地换了行为」——
#      光看退出码永远看不见它。
#
# usage: ./overflow-check.sh [binary]
set -uo pipefail

BIN="${1:-$HOME/.config/mise/dotfiles/.local/bin/scripts/qb-open}"
export BIN
mkdir -p ./out

unshare -rm --propagation private bash -c '
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"
mount --bind /bin/true /usr/bin/qutebrowser || exit 1

export XDG_RUNTIME_DIR=./rt-overflow
rm -rf "$XDG_RUNTIME_DIR"; mkdir -p "$XDG_RUNTIME_DIR/qutebrowser"
./fake-sock.py "$XDG_RUNTIME_DIR/qutebrowser/ipc-fake" >/dev/null 2>"$XDG_RUNTIME_DIR/msgs" &
srv=$!
trap "kill $srv 2>/dev/null; wait $srv 2>/dev/null; exit 0" EXIT INT TERM
for _ in $(seq 1 100); do [[ -S "$XDG_RUNTIME_DIR/qutebrowser/ipc-fake" ]] && break; sleep 0.02; done

# 跑一个长度，打印一行，并记进 out/summary.tsv。
# 这一行的四个字段留在 p_n / p_rc / p_sent / p_fb 里，供下面解说时引用。
probe() {
    local n="$1" arg before after ev ptr
    arg=$(printf "A%.0s" $(seq 1 "$n"))
    before=$(stat -c%s "$XDG_RUNTIME_DIR/msgs")
    strace -f -o "out/ovf-$n.txt" "$BIN" "$arg" >/dev/null 2>&1
    p_rc=$?
    after=$(stat -c%s "$XDG_RUNTIME_DIR/msgs")
    p_sent=$(( after - before ))
    p_n=$n

    # fallback 那条 execve。要排掉第一条 —— 那是 strace 自己 exec 启动器的记录，
    # 每条 trace 里都有，不排掉的话每个长度看起来都「fallback 过」。
    ev=$(grep -oE "execve\(\"[^\"]*\", \[[^]]*\], 0x[0-9a-f]+" "out/ovf-$n.txt" |
         grep -v "^execve(\"$BIN\"" | head -1)
    p_fb="-"
    if [[ -n "$ev" ]]; then
        ptr=${ev##*, }
        p_fb="execve envp=$ptr"
    fi
    printf "  %-8s %-5s %-12s %s\n" "$p_n" "$p_rc" "$p_sent" "$p_fb"
    printf "%s\t%s\t%s\t%s\n" "$p_n" "$p_rc" "$p_sent" "$p_fb" >>out/summary.tsv
}

cat <<'BANNER'

  这个实验要回答：qb-open 那条 8192 字节的缓冲区，参数比它长的时候会发生什么？

  一个长度一行。跑在私有 mount namespace 里，/usr/bin/qutebrowser 已经绑成 /bin/true ——
  fallback 真触发时 exec 的是它，不是浏览器：
BANNER

printf "\n  %-8s %-5s %-12s %s\n" n rc bytes_sent fallback_trace
: >out/summary.tsv

# 8043 是正好填满 8192 的那个长度，8044 是第一个越界的长度 —— 边界扫到个位数
for n in 8000 8042 8043 8044 8050 8100 8300; do probe "$n"; done

ok_line=$(awk -F"\t" "\$3>0{n=\$1;s=\$3;r=\$2} END{if(n) print n\" 字节（socket 收到 \"s\" 字节，rc=\"r\"）\"}" out/summary.tsv)
zero_n=$(awk -F"\t" "\$3==0{print \$1; exit}" out/summary.tsv)
fb_n=$(awk -F"\t" "\$4!=\"-\"{print \$1; exit}" out/summary.tsv)
rcs=$(awk -F"\t" "{print \$2}" out/summary.tsv | sort -u | paste -sd, -)

cat <<EOF

  边界        最后一个还能发出去的长度 —— $ok_line；从 $zero_n 起 bytes_sent 一直是 0
  第一个兜底  从 $fb_n 起，trace 里多出一条 execve —— 它悄悄换了个浏览器起来
  退出码      整张表里出现过 $rcs —— 从头到尾没有一行在报错

  越界之后它不崩溃、不报错，而是*行为变了*；这用在哪：错的工具如果当场报错，你早换掉了。
EOF
'
