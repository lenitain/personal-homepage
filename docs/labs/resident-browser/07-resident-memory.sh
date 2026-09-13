#!/bin/bash
# 实验 8：常驻浏览器到底占多少内存
#
# 「常驻成本」是这个方案里唯一被反复引用、却最容易凭印象说话的数字。所以量它。
#
# 难点是**别打扰正在用的那个实例**。做法是起一个完全隔离的临时实例：
#
#   - 自己一个 XDG_RUNTIME_DIR，里面用软链把真实的那些 socket（wayland / dbus /
#     pipewire / …）**除 qutebrowser/ 之外**全部借过来 —— 于是它什么都能连上，
#     但它自己的 IPC socket 落在隔离目录里，不会被 qb-open 扫到，也不会跟真实实例抢。
#   - 自己一个 --basedir，profile 与真实实例无关。
#   - 用 systemd 临时 scope 跑，这样能直接读它的 cgroup 内存。
#
# 两个对照组，回答两个不同的问题：
#   A 空 profile，零窗口   —— 引擎本身的底价
#   B 真实 profile，零窗口 —— 加上历史/书签/cookie 之后的底价
#
# 用法: ./07-resident-memory.sh [真实 profile 的路径]
set -uo pipefail

REAL_PROFILE="${1:-$HOME/.local/share/qutebrowser}"
REAL_RUNTIME="${XDG_RUNTIME_DIR:?需要 XDG_RUNTIME_DIR}"
UNIT="memlab-$$"
WORK=$(mktemp -d)

cleanup() {
    systemctl --user stop "$UNIT.scope" >/dev/null 2>&1
    systemctl --user reset-failed "$UNIT.scope" >/dev/null 2>&1
    sleep 0.5
    rm -rf "$WORK"
}
trap cleanup EXIT

# 起一个隔离实例，参数是 basedir。等它内存读数稳定后打印。
measure() {
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
    disown

    # 等它起来
    local waited=0
    while (( waited < 60 )); do
        systemctl --user is-active "$UNIT.scope" >/dev/null 2>&1 && break
        sleep 0.5
        (( waited++ ))
    done
    sleep 15

    # 连读三次，确认已经稳定而不是还在爬
    local readings=() value
    for _ in 1 2 3; do
        value=$(systemctl --user show "$UNIT.scope" -p MemoryCurrent --value 2>/dev/null)
        readings+=("$(( ${value:-0} / 1048576 ))")
        sleep 5
    done
    local tasks
    tasks=$(systemctl --user show "$UNIT.scope" -p TasksCurrent --value 2>/dev/null)

    printf '  %-28s %s MiB（三次读数: %s）  任务数 %s\n' \
        "$label" "${readings[0]}" "${readings[*]}" "$tasks"

    systemctl --user stop "$UNIT.scope" >/dev/null 2>&1
    sleep 2
}

printf '真实 profile: %s\n\n' "$REAL_PROFILE"

printf 'A) 空 profile、零窗口 —— 引擎本身的底价\n'
measure "empty" "$WORK/base-empty"

printf '\nB) 真实 profile、零窗口\n'
# 只读拷贝，绝不碰原件
mkdir -p "$WORK/base-real/data"
cp -a "$REAL_PROFILE/." "$WORK/base-real/data" 2>/dev/null
printf '  （profile 大小 %s）\n' "$(du -sh "$WORK/base-real/data" | cut -f1)"
measure "real" "$WORK/base-real"

printf '\nC) 你正在用的那个实例（带若干标签页，仅供参考）\n'
if systemctl --user is-active qb-server.service >/dev/null 2>&1; then
    live=$(systemctl --user show qb-server.service -p MemoryCurrent --value)
    peak=$(systemctl --user show qb-server.service -p MemoryPeak --value)
    printf '  qb-server.service           %s MiB（峰值 %s MiB）  任务数 %s\n' \
        "$(( live / 1048576 ))" "$(( peak / 1048576 ))" \
        "$(systemctl --user show qb-server.service -p TasksCurrent --value)"
else
    printf '  qb-server.service 没在跑，跳过\n'
fi
