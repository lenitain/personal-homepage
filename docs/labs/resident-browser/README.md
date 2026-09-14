# resident-browser 实验器材

`content/hacks/resident-browser/` 那五章课件里贴的实验，脚本都在这里。
每一章的输出都是这些脚本跑出来的，不是手抄的。

## 跑之前

- **测量脚本要绑核。** 在一台开着桌面会话的机器上不绑核，同一份代码的读数能差一半。
  `latency.sh` / `python-split.sh` 内部已经 `taskset` 了。
- **`overflow-check.sh` 会自己进 mount namespace。** 那个 bug 的失败模式里包含
  「`execve` 成功」这一种，所以它把 `/bin/true` 绑到 `/usr/bin/qutebrowser` 上再跑。
  不要绕过这层。
- **`12-resident-memory.sh` 会起一个隔离的浏览器实例。** 它借真实 runtime dir 里除
  `qutebrowser/` 之外的所有 socket，所以连得上合成器，但自己的 IPC socket 落在临时目录里，
  不会跟你在用的实例抢。跑完自动清理。
- **`06-one-copy.sh` 要造一个 2 GiB 的共享库**（「100 个进程共用一份」那个反证用的素材）。
  它会往工作目录里写 2 GiB 真实字节，跑一次约 20 秒。空间不够会自动减半，
  也可以自己指定：`./06-one-copy.sh 512`。

## 脚本

| 脚本 | 对应章节 | 干什么 |
| --- | --- | --- |
| `01-fork.sh` | 我的 qutebrowser 启动好慢 | fork 复制一份自己：两个进程，唯一的区别是 pid |
| `02-execve.sh` | 我的 qutebrowser 启动好慢 | execve 换内容不换进程：pid 不变 |
| `03-redirect.sh` | 我的 qutebrowser 启动好慢 | fork 和 exec 之间那一步：shell 重定向就是这么实现的 |
| `04-address-space.sh` | 我的 qutebrowser 启动好慢 | 全系统地址空间加起来 6 TiB，物理内存 15 GiB |
| `05-mmap-not-occupied.sh` | 我的 qutebrowser 启动好慢 | 映射 1 GiB 物理内存不涨；碰多少涨多少 |
| `06-one-copy.sh` | 我的 qutebrowser 启动好慢 | 100 个进程各读一遍 2 GiB 的库，物理内存里只有一份 |
| `07-elf-loading.sh` | 我的 qutebrowser 启动好慢 | 段表与地址空间一一对应；execve 之后内核和链接器发的系统调用；静态 vs 动态的启动开销 |
| `08-dynamic-loader.sh` | 我的 qutebrowser 启动好慢 | 找库 / 重映射 / 重定位 / 调 init；惰性绑定 vs `-z now` |
| `09-zygote-prefork.sh` | 我的 qutebrowser 启动好慢 | fork 继承 vs exec 重来；真实 QtWebEngine zygote |
| `10-namespace-failure-modes.sh` | 谁来收尸 | 非特权建 PID namespace、空 uid_map、杀 wrapper |
| `11-cgroup-vs-mainpid.sh` | 谁来收尸 | scope 与 service 的 MainPID 差异；三种启动方式的收尸对比 |
| `12-resident-memory.sh` | 什么样的程序值得常驻 / 什么该留在 RAM | 孤立实例量常驻成本（空 profile / 真实 profile / 在用的那个） |
| `13-qutebrowser-checkup.sh` | 我的 qutebrowser 启动好慢 / 什么样的程序值得常驻 | 970 字节的 Python 脚本；模块导入账单；把启动切成几段 |
| `overflow-check.sh` | 快路径用什么写 | C 版缓冲区溢出的边界，安全网内 |
| `launchers/` | 快路径用什么写 | 同一个启动器的九种实现、五种语言 |

## 前九个脚本互相独立

`01`–`09` 各自 `mktemp -d` 自己造素材、跑完自己删，不依赖仓库里任何东西，
也不需要 root。直接跑就行：

```sh
./01-fork.sh
./02-execve.sh
./03-redirect.sh
./04-address-space.sh
./05-mmap-not-occupied.sh
./06-one-copy.sh                  # 要往工作目录写 2 GiB，约 20 秒
./07-elf-loading.sh
./08-dynamic-loader.sh
./09-zygote-prefork.sh            # 这个会顺便读你机器上真实的 QtWebEngine 进程
./10-namespace-failure-modes.sh   # 需要非特权 user namespace 可用
./11-cgroup-vs-mainpid.sh         # 需要 systemd --user
```

`fake-sock.py` + `mkfake.sh` 提供一个假的 qutebrowser IPC socket。
**所有测量都必须对着它跑** —— 否则启动器连不上 socket 会走 fallback，
真的 exec 出一个浏览器来，测的就不是启动器了。
