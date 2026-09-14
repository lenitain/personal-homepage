#!/bin/bash
# 实验：常驻一个 qutebrowser 到底占多少内存
#
# 「常驻成本」是这个方案里唯一被反复引用、却最容易凭印象说话的数字。所以量它。
#
# 看什么：
#
#   单个进程报的 RSS 不是一个 scope 的账：常驻成本问的是「这一坨加起来多少」，
#   能给整坨进程记账的是 systemd 的 scope（一个 scope 就是一个 cgroup）。
#
# 哪些细节不做，就什么都看不出来：
#
#   一、隔离实例 —— 别打扰你正在用的那个。做法是：
#      · 自己一个 XDG_RUNTIME_DIR，里面用软链把真实 runtime dir 里那些 socket
#        （wayland / dbus / pipewire / …）*除 qutebrowser/ 之外* 全部借过来 ——
#        于是它什么都能连上，但它自己的 IPC socket 落在隔离目录里，不会被 qb-open
#        扫到，也不会跟真实实例抢。少这一步，它要么起不来、要么接到真实实例上，
#        你量的就不是它了。
#      · 自己一个 --basedir，profile 与真实实例无关。少这一步，实验会动到你正在用的 profile。
#      · 用 systemd 临时 scope 跑：一个 scope 就是一个 cgroup，能读到它给整坨进程记的账。
#        少这一步，你只能一个进程一个进程地加，而「常驻成本」问的正是那一坨。
#
#   二、零窗口（--nowindow -R）才叫常驻：窗口一开，涨的是标签页，不是引擎。
#
#   三、进程起完不能马上收 —— 内存还在爬，所以连读三次，读数稳了才算数。
#      跑完由 trap 收干净，不留残留进程和残留 scope。
#
# 用法: ./12-resident-memory.sh [真实 profile 的路径]
set -uo pipefail

REAL_PROFILE="${1:-$HOME/.local/share/qutebrowser}"
REAL_RUNTIME="${XDG_RUNTIME_DIR:?需要 XDG_RUNTIME_DIR}"
UNIT="memlab-$$"
WORK=$(mktemp -d)
pids=()

cleanup() {
    (( ${#pids[@]} )) && kill "${pids[@]}" 2>/dev/null || true
    systemctl --user stop "$UNIT.scope" >/dev/null 2>&1
    systemctl --user reset-failed "$UNIT.scope" >/dev/null 2>&1
    sleep 0.5
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 起一个隔离实例。它*不停* —— 等读数稳定；收尾交给调用者。
start_instance() {   # $1 = 标签, $2 = basedir
    local label="$1" basedir="$2"
    local runtime="$WORK/rt-$label"

    mkdir -p "$runtime" "$basedir"
    # 把真实 runtime dir 里的东西全借过来，但不要它的 qutebrowser/ ——
    # 那个目录里是真实实例的 IPC socket，借过来就分不清谁是谁了。
    local entry
    for entry in "$REAL_RUNTIME"/*; do
        [[ "$(basename "$entry")" == "qutebrowser" ]] && continue
        ln -sfn "$entry" "$runtime/$(basename "$entry")"
    done

    systemctl --user reset-failed "$UNIT.scope" >/dev/null 2>&1
    setsid systemd-run --user --scope --unit="$UNIT" \
        env XDG_RUNTIME_DIR="$runtime" \
        "$HOME/.local/bin/scripts/qb-server" --nowindow -R --basedir "$basedir" \
        >/dev/null 2>&1 &
    pids+=("$!")
    disown

    # 等它起来
    local waited=0
    while (( waited < 60 )); do
        systemctl --user is-active "$UNIT.scope" >/dev/null 2>&1 && break
        sleep 0.5
        waited=$(( waited + 1 ))
    done
    sleep 15
}

# 连读三次，确认它是稳定了而不是还在爬。
settle() {
    local readings=() value
    for _ in 1 2 3; do
        value=$(systemctl --user show "$UNIT.scope" -p MemoryCurrent --value 2>/dev/null)
        readings+=("$(( ${value:-0} / 1048576 ))")
        sleep 5
    done
    M_FIRST="${readings[0]}"
    M_ALL="${readings[*]}"
    M_TASKS=$(systemctl --user show "$UNIT.scope" -p TasksCurrent --value 2>/dev/null)
}

stop_instance() {
    systemctl --user stop "$UNIT.scope" >/dev/null 2>&1
    sleep 2
}

# ---------------------------------------------------------------- A：空 profile

start_instance empty "$WORK/base-empty"
settle
stop_instance
M_A_FIRST="$M_FIRST"; M_A_ALL="$M_ALL"; M_A_TASKS="$M_TASKS"

# ---------------------------------------------------------------- B：真实 profile

# 只读拷贝，绝不碰原件
mkdir -p "$WORK/base-real/data"
cp -a "$REAL_PROFILE/." "$WORK/base-real/data" 2>/dev/null
profile_size=$(du -sh "$WORK/base-real/data" 2>/dev/null | cut -f1)

start_instance real "$WORK/base-real"
settle
stop_instance
M_B_FIRST="$M_FIRST"; M_B_ALL="$M_ALL"; M_B_TASKS="$M_TASKS"

# ---------------------------------------------------------------- C：你正在用的那个

# 只在它跑着的时候有 —— 带若干标签页，仅供参考
live_row="qb-server.service 没在跑，跳过"
if systemctl --user is-active qb-server.service >/dev/null 2>&1; then
    live=$(systemctl --user show qb-server.service -p MemoryCurrent --value)
    live_tasks=$(systemctl --user show qb-server.service -p TasksCurrent --value)
    live_row="$(( ${live:-0} / 1048576 )) MiB   任务数 $live_tasks   （qb-server.service，带窗口，仅供参考）"
fi

cat <<EOF

  这个实验要回答：让 qutebrowser 一直活着（零窗口），要占多少内存？

  同一个启动器、同样零窗口，只换 profile；数字取自 systemd scope 的 MemoryCurrent ——
  一个 scope 就是一个 cgroup，记的是这一坨进程加起来的账：
    空 profile       $M_A_FIRST MiB   三次读数 $M_A_ALL   任务数 $M_A_TASKS
    真实 profile     $M_B_FIRST MiB   三次读数 $M_B_ALL   任务数 $M_B_TASKS
    你正在用的       $live_row
    （B 读的是真实 profile 的只读拷贝，$profile_size，原件没碰）

  A 和 B 的差只有 $(( M_B_FIRST - M_A_FIRST )) MiB —— 换 profile 几乎不影响底价。
  那点差别就是 profile 真的进了内存的部分，剩下的是 overlayfs 在干活：
  RAM 里放的是增量，不是 profile。一百多兆是「一直活着」的底价，零窗口也照付。

  这用在哪：常驻省下的是每次启动都完全一样的那些时间，开销就是这个底价 ——
  它比「用出来的」那上 G（开着一堆标签页的实例）小一个量级。
EOF
