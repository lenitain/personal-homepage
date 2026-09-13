#!/bin/bash
# 侦察运行：起一次 qutebrowser，全程 strace，然后按进程组收尸。
# 写成文件是因为内联命令里出现过的模式串会匹配到我自己的 shell。
set -u
cd /tmp/qbphase || exit 1

CLEAN=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SECONDS_TO_RUN="${1:-20}"

setsid env -i PATH="$CLEAN" HOME="$HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    strace -f -tt -o trace.txt \
    /usr/bin/qutebrowser -R 'about:blank' >/dev/null 2>&1 &
PGID=$!

sleep "$SECONDS_TO_RUN"

# 按进程组收：负号表示整个组
kill -TERM -"$PGID" 2>/dev/null
sleep 2
kill -KILL -"$PGID" 2>/dev/null
sleep 1

echo "残留 qutebrowser: $(pgrep -xc qutebrowser 2>/dev/null || echo 0)"
echo "残留 QtWebEngine: $(pgrep -xc QtWebEngineProc 2>/dev/null || echo 0)"
echo "trace 行数: $(wc -l < trace.txt 2>/dev/null || echo 0)"
echo "进程数: $(awk '{print $1}' trace.txt 2>/dev/null | sort -u | wc -l)"
echo "起止: $(head -1 trace.txt | cut -c1-15)  →  $(tail -1 trace.txt | cut -c1-15)"
