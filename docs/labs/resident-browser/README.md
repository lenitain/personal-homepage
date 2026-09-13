# resident-browser 实验器材

`content/hacks/resident-browser/` 那五章课件里贴的实验，脚本都在这里。
每一章的输出都是这些脚本跑出来的，不是手抄的。

## 跑之前

- **测量脚本要绑核。** 在一台开着桌面会话的机器上不绑核，同一份代码的读数能差一半。
  `latency.sh` / `python-split.sh` 内部已经 `taskset` 了。
- **`overflow-check.sh` 会自己进 mount namespace。** 那个 bug 的失败模式里包含
  「`execve` 成功」这一种，所以它把 `/bin/true` 绑到 `/usr/bin/qutebrowser` 上再跑。
  不要绕过这层。
- **`07-resident-memory.sh` 会起一个隔离的浏览器实例。** 它借真实 runtime dir 里除
  `qutebrowser/` 之外的所有 socket，所以连得上合成器，但自己的 IPC socket 落在临时目录里，
  不会跟你在用的实例抢。跑完自动清理。

## 脚本

| 脚本 | 对应章节 | 干什么 |
| --- | --- | --- |
| `02-elf-loading.sh` | 一个进程是怎么起来的 | 段表与地址空间一一对应；execve 之后内核和链接器发的系统调用 |
| `03-dynamic-loader.sh` | 一个进程是怎么起来的 | 找库 / 重映射 / 重定位 / 调 init；惰性绑定 vs `-z now` |
| `04-zygote-prefork.sh` | 一个进程是怎么起来的 | fork 继承 vs exec 重来；真实 QtWebEngine zygote |
| `05-namespace-failure-modes.sh` | 谁负责收尸 | 非特权建 PID namespace、空 uid_map、杀 wrapper |
| `06-cgroup-vs-mainpid.sh` | 谁负责收尸 | scope 与 service 的 MainPID 差异；三种启动方式的收尸对比 |
| `07-resident-memory.sh` | 什么该留在 RAM | 孤立实例量常驻成本（空 profile / 真实 profile / 在用的那个） |
| `overflow-check.sh` | 快路径用什么写 | C 版缓冲区溢出的边界，安全网内 |
| `launchers/` | 快路径用什么写 | 同一个启动器的九种实现、五种语言 |

## 前三个脚本互相独立

`04` / `05` / `06` 各自 `mktemp -d` 自己造素材、跑完自己删，不依赖仓库里任何东西，
也不需要 root。直接跑就行：

```sh
./02-elf-loading.sh
./03-dynamic-loader.sh
./04-zygote-prefork.sh      # 最后一个会顺便读你机器上真实的 QtWebEngine 进程
```

## 启动器基准的流程

```sh
./build-all.sh          # 九种实现各构建两遍：原样 + strip
./verify.sh             # 八个用例逐字节对比 C 版（不过这一关，延迟没有意义）
./latency.sh out 3 500  # 绑核、三轮、报最小值
./python-split.sh       # 把 Python 的 22 ms 拆成解释器 / 导入 / 自己的逻辑
./measure.sh out 1000   # syscall 计数 + exec 时刻的地址空间
```

`fake-sock.py` + `mkfake.sh` 提供一个假的 qutebrowser IPC socket。
**所有测量都必须对着它跑** —— 否则启动器连不上 socket 会走 fallback，
真的 exec 出一个浏览器来，测的就不是启动器了。
