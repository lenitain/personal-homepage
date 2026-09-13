#!/usr/bin/python3
"""假的 qutebrowser IPC socket —— 只 accept + 读干净 + 关闭。

存在的意义：让 qb-open 的各个语言实现有一个「成功路径」的靶子。没有它，
任何实现只要连不上 socket 就会 fallback 到 execve(/usr/bin/qutebrowser)，
测量就变成了「启动一个浏览器」，而且会污染用户的真实会话。

用法: fake-sock.py <socket-path> [连接数上限]
连接数上限用于把 server 的生命周期绑死，避免残留。默认无限。
所有收到的消息写到 stderr（可重定向），每行一条，带字节数。
"""
import os
import socket
import sys


def main() -> int:
    path = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(128)

    # 让父进程知道 socket 已经就绪，可以开始压了。
    print("READY", flush=True)

    n = 0
    while limit == 0 or n < limit:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        with conn:
            total = 0
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                total += len(chunk)
                sys.stderr.write(chunk.decode("utf-8", "replace"))
                sys.stderr.flush()
        n += 1

    srv.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
