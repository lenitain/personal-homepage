#!/usr/bin/python3
"""qb-open in Python — the honest version, not a straw man.

The point of this file is to measure what the *launcher* costs when you write it
in the language qutebrowser itself is written in. So it is written the way you
would actually write it: stdlib `json` for the message, stdlib `socket` for the
transport, `os.listdir` for the scan. No hand-rolled micro-optimisations, because
the interesting number is the one you get without trying.

The one concession to byte-compatibility is `separators` and `ensure_ascii`,
which make `json.dumps` emit exactly the same bytes as the C version instead of
its default `", "` / `": "` spacing. That is a formatting choice, not a
performance trick.

Fallback: no socket -> exec the real browser, argv intact.
"""
import json
import os
import socket
import sys

QUTEBROWSER = "/usr/bin/qutebrowser"


def find_ipc_socket(runtime_dir: str) -> str | None:
    """First `ipc-*` entry under <runtime_dir>/qutebrowser, or None.

    Scanning for the prefix rather than computing qutebrowser's md5(username)
    socket name keeps this working if upstream ever changes that scheme.
    """
    directory = os.path.join(runtime_dir, "qutebrowser")
    try:
        entries = os.listdir(directory)
    except OSError:
        return None

    for name in entries:
        if name.startswith("ipc-"):
            return os.path.join(directory, name)
    return None


def main() -> int:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    socket_path = find_ipc_socket(runtime_dir)

    if socket_path is not None:
        message = {
            "args": sys.argv[1:] or [""],
            "target_arg": None,
            "version": "3.7.0",
            "protocol_version": 1,
        }
        try:
            message["cwd"] = os.getcwd()
        except OSError:
            pass

        payload = json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n"
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.connect(socket_path)
                sock.sendall(payload.encode())
            return 0
        except OSError:
            pass

    os.execv(QUTEBROWSER, [QUTEBROWSER, *sys.argv[1:]])
    return 1


if __name__ == "__main__":
    sys.exit(main())
