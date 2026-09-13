#!/bin/bash
# 起一个假的 XDG_RUNTIME_DIR，里面摆一个假的 qutebrowser IPC socket。
# 用法: eval "$(mkfake.sh <tag>)"  —— 会导出 XDG_RUNTIME_DIR / FAKE_PID
#
# tag 用来区分并发跑的实例，避免抢同一个路径。
set -euo pipefail

TAG="${1:-default}"
ROOT="./rt-$TAG"
SOCK="$ROOT/qutebrowser/ipc-fake"

rm -rf "$ROOT"
mkdir -p "$ROOT/qutebrowser"

./fake-sock.py "$SOCK" >"$ROOT/ready" 2>"$ROOT/messages" &
FAKE_PID=$!

# 等 server 真的 bind 完
for _ in $(seq 1 200); do
    [[ -s "$ROOT/ready" ]] && break
    sleep 0.01
done

echo "export XDG_RUNTIME_DIR=$ROOT"
echo "export FAKE_PID=$FAKE_PID"
echo "export FAKE_SOCK=$SOCK"
