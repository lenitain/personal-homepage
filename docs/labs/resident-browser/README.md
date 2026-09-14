# resident-browser 实验器材

`content/hacks/resident-browser/` 那份课件里贴的实验，脚本都在这里 ——
正文是序加四章。每一节里贴的输出都是这些脚本跑出来的，不是手抄的。

脚本为**决定**服务，不为「演示某个数字」服务：哪个决定点需要什么量、
哪些事实缺实验、哪些脚本已经多余，见 `docs/courseware-design.md`。

正文只引用那些「不量就会做出不同决定」的实验。所以表里少数脚本在正文中
已经不再单独成节（例如 `04-address-space.sh` 并进了序里的一段），
它们仍然可以跑 —— 留着是因为想复现随时能复现，不是因为正文还在引它。

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
- **`14-identity-channels.sh` 要在一台有会话的机器上跑**（session bus 和 Wayland 都得在）。
  它自己 `unshare --user` 建一个空映射的 namespace，跟 broker 说一句 SASL 握手、
  向合成器要一份 registry —— 两条都是只读，不碰你正在用的实例。

## 脚本

| 脚本 | 对应章节 | 干什么 |
| --- | --- | --- |
| `01-fork.sh` | 序 | fork 复制一份自己：两个进程，唯一的区别是 pid |
| `02-execve.sh` | 序 | execve 换内容不换进程：pid 不变 |
| `03-redirect.sh` | 序 | fork 和 exec 之间那一步：shell 重定向就是这么实现的 |
| `04-address-space.sh` | 序 | 所有进程地址空间加起来（7 TiB）是物理内存（15 GiB）的几百倍 |
| `05-mmap-not-occupied.sh` | 序 | 映射 1 GiB 物理内存不涨；碰多少涨多少 |
| `06-one-copy.sh` | 序 | 100 个进程各读一遍 2 GiB 的库，物理内存里只有一份 |
| `06b-libc-shared.sh` | 序 | 六个进程共用同一份真实的 libc：Rss 相加是假数，Pss 相加才是物理内存 |
| `07-elf-loading.sh` | 第 4 章 | 段表与地址空间一一对应；execve 之后内核和链接器发的系统调用；静态 vs 动态的启动开销 |
| `08-dynamic-loader.sh` | 第 4 章 | 找库 / 重映射 / 重定位 / 调 init；惰性绑定 vs `-z now` |
| `09-zygote-prefork.sh` | 第 1 章 | fork 继承 vs exec 重来；真实 QtWebEngine zygote |
| `10-namespace-failure-modes.sh` | 第 2 章 | 非特权建 PID namespace、空 uid_map、杀 wrapper |
| `11-cgroup-vs-mainpid.sh` | 第 2 章 | scope 与 service 的 MainPID 差异；三种启动方式的资源释放对比 |
| `12-resident-memory.sh` | 第 1 章 / 第 3 章 | 孤立实例量常驻成本（空 profile / 真实 profile / 在用的那个） |
| `13-qutebrowser-checkup.sh` | 序 / 第 1 章 | 970 字节的 Python 脚本；模块导入账单；把启动切成几段 |
| `14-identity-channels.sh` | 第 2 章 | 空的 user namespace 里：D-Bus 的 `AUTH EXTERNAL` 被 REJECTED，Wayland 照通 |
| `15-orphan-reaping.sh` | 第 2 章 | 父进程退出后子进程归谁（最近的 subreaper / pid 1）；接管 ≠ 收拾 |
| `16-page-cache.sh` | 第 3 章 | 读过的文件占的内存可以还回去；还回去之后文件照样在用 |
| `17-tmpfs-not-reclaimable.sh` | 第 3 章 | 同一个 64 MiB 的 cgroup 里：文件页回收得掉，tmpfs 页回收不掉 |
| `overflow-check.sh` | 第 4 章 | C 版缓冲区溢出的边界，安全网内 |
| `launchers/` | 第 4 章 | 同一个启动器的九种实现、五种语言 |

## 这些脚本互相独立

`01`–`11`、`14`–`17` 各自自己造素材、跑完自己删（工作目录优先放 `/var/tmp`，
因为 `/tmp` 常常是 tmpfs，那两个缓存实验在 tmpfs 上做不出结论），
不依赖仓库里任何东西，也不需要 root。直接跑就行：

```sh
./01-fork.sh
./02-execve.sh
./03-redirect.sh
./04-address-space.sh
./05-mmap-not-occupied.sh
./06-one-copy.sh                  # 要往工作目录写 2 GiB，约 20 秒
./06b-libc-shared.sh              # 不造素材，量机器上真实的 libc，一两秒
./07-elf-loading.sh
./08-dynamic-loader.sh
./09-zygote-prefork.sh            # 这个会顺便读你机器上真实的 QtWebEngine 进程
./10-namespace-failure-modes.sh   # 需要非特权 user namespace 可用
./11-cgroup-vs-mainpid.sh         # 需要 systemd --user
./14-identity-channels.sh         # 需要有会话（session bus + Wayland）
./15-orphan-reaping.sh            # 不需要特权
./16-page-cache.sh                # 需要非 tmpfs 的目录放素材（优先 /var/tmp）
./17-tmpfs-not-reclaimable.sh     # 需要 systemd --user 的 memory 控制器 + 一个 tmpfs
```

`fake-sock.py` + `mkfake.sh` 提供一个假的 qutebrowser IPC socket。
**所有测量都必须对着它跑** —— 否则启动器连不上 socket 会走 fallback，
真的 exec 出一个浏览器来，测的就不是启动器了。
