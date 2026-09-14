#!/bin/bash
# 实验：同一个 user namespace 里，哪些通道断了、断在哪一步
#
# 承接 10 —— 那里量到：空的 user namespace 里 getuid() 是 65534。
# 这一份拿两条真实通道各走一遍，看这个「没有身份」打在谁身上：
# 先认证的那条断在握手第一句，不用认证的那条照通。
#
# 形态说明：两条通道都是自己说协议，不借助任何库 —— libdbus 会替你把凭据算好，
# 而要看的就是它算出来的那个 uid，跟内核报给 broker 的 uid 是不是同一个。
#
# 关键细节：两条都是「连得上」的。差别不在连接层，在认证层 ——
# 只测 connect() 成不成功，这个坑看不出来。
#
# 对应《谁来释放资源》第 4 节「按身份认人的通道全部断掉」。
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! unshare --user -- true 2>/dev/null; then
    echo "  这台机器不放开非特权 user namespace，这个实验跑不了。"
    exit 0
fi

cat >"$WORK/probe.py" <<'PY'
import os, socket, struct, sys, time

def session_bus_path():
    addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
    if "path=" in addr:
        return addr.split("path=")[1].split(",")[0]
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "bus")

def wayland_path():
    name = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    if name.startswith("/"):
        return name
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), name)

def probe_dbus():
    """自己说 D-Bus 的 SASL 握手：第一句话就是自报身份。"""
    uid = os.getuid()
    cred = str(uid).encode().hex()      # libdbus 用的就是这个：uid 的十进制字符串，再取十六进制
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(session_bus_path())
    s.sendall(b"\0AUTH EXTERNAL " + cred.encode() + b"\r\n")
    data = b""
    while b"\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    print(uid, cred, data.split(b"\r\n")[0].decode(errors="replace"))

def probe_wayland():
    """要一份 registry 回来：connect 之后，没有任何一步问你是谁。"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(wayland_path())
    # id 1 是 wl_display，客户端自己分配的对象从 2 开始
    s.sendall(struct.pack("<II", 1, (12 << 16) | 1) + struct.pack("<I", 2))   # get_registry(new_id=2)
    s.sendall(struct.pack("<II", 1, (12 << 16) | 0) + struct.pack("<I", 3))   # sync(new_id=3)
    total = 0
    deadline = time.time() + 1.5
    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        total += len(chunk)
    s.close()
    print(total)

if sys.argv[1] == "dbus":
    probe_dbus()
else:
    probe_wayland()
PY

probe() { python3 "$WORK/probe.py" "$1"; }

read -r h_uid h_cred h_reply <<<"$(probe dbus)"
read -r n_uid n_cred n_reply <<<"$(unshare --user -- python3 "$WORK/probe.py" dbus)"
h_wl=$(probe wayland)
n_wl=$(unshare --user -- python3 "$WORK/probe.py" wayland)

# ------------------------------------------------ 一张表（挑出来的原始输出）

cat <<EOF

  这个实验要回答：同一个 user namespace 里，哪些通道断了、断在哪一步？

  uid：宿主上 $h_uid；空的 namespace 里 $n_uid（uid_map 是空的，内核拿 overflow uid 顶上）

  D-Bus —— 先认证，第一句话就是自报身份
    宿主上          声称 $h_uid，AUTH EXTERNAL $h_cred    → $h_reply
    空的 namespace  声称 $n_uid，AUTH EXTERNAL $n_cred → $n_reply

  Wayland —— 裸 connect，连上就说，没有一步问你是谁
    宿主上          connect 成功，要回 registry，$h_wl 字节
    空的 namespace  connect 成功，要回 registry，$n_wl 字节

  差别不在「连不连得上」，在「要不要先证明你是谁」：D-Bus 的应答来自 broker，
  它不在你的 namespace 里，拿内核报的 uid（$h_uid）跟你声称的那个一比，对不上就 REJECTED。
  fcitx5 住在 session bus 上，于是输入法整块消失，而画面、声音、键盘全都正常。

  用在哪：「断的不是所有 IPC，是所有需要身份的 IPC」这句话的原始记录就是这两行应答。
EOF
