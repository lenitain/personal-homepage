#import ".course.typ": title, think, wrong, lab

#set document(title: "谁负责收尸")

#title[谁负责收尸]

一个常驻浏览器，是一个比启动它的东西活得更久的进程。这正是《什么样的程序值得常驻》那一章
的全部意义，也是你当场欠下的一笔账：*早晚得有人来关掉它。*

而这笔账比看上去大。一个 qutebrowser 不是一个进程，是五个：本体加一小群 QtWebEngine 帮手，
其中一个是 Chromium 的 renderer，占着几百兆内存也照样心安理得。收尸要收的是一整棵树。

= 我的第一反应：PID namespace

`unshare --pid --fork`，把整棵树关进去。namespace 的 init 一死，内核回收整个 namespace ——
隔离和收尸一次搞定，一个原语解决两个问题。

#think[
  这个方案有什么问题？

  先自己回答一句，再往下看。答案不是「它不管用」——恰恰相反，它管用，这才是陷阱。
]

= 第一层：它根本没打算做这件事

#lab("实验 1：非特权用户能单独创建 PID namespace 吗")[
  ```sh
  $ unshare --pid --fork --mount-proc true
  unshare: unshare 失败: 不允许的操作
  ```

  退出码 1。普通用户拿不到 PID namespace —— 只有 root 可以。所以想用这条路的普通人，
  *必须先用 `--user` 建一个 user namespace*。而那个 user namespace，就是后面所有麻烦的源头。
]

#lab("实验 2：那先建 user namespace，uid 会变成什么")[
  ```sh
  $ unshare --user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"
  65534
  (↑ getuid，↓ uid_map)
  ```

  `uid_map` 是*空的*。空映射之下，`getuid()` 拿不到你的 uid，内核拿 overflow uid 顶上，
  也就是 65534。

  加上 `--map-current-user` 才会把你映进去：

  ```sh
  $ unshare --user --map-current-user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"
  1000
        1000       1000          1
  ```
]

这一段值得停一下。*user namespace 的默认状态是「你没有身份」*，不是「你还是你」。
要变成你，得显式地说出来。而「没有身份」这件事，对大多数程序是无害的 —— 直到它碰到一个
需要知道你是谁的地方。

= 第二层：输入法是怎么死的

给 `unshare` 补上 `--map-current-user` 之后，浏览器一切正常。页面渲染、滚动、视频、快捷键，
全都对。

只有一件事不对：*打不出中文。*

不是候选词不出来，也不是候选框位置错了 —— 是输入法像根本不存在。这个描述很重要，
因为「转换不出来」和「根本没接上」是两类完全不同的故障，而当时我花了不少时间按前一类去查。

#think[
  同一个 namespace 里，浏览器渲染页面、播放视频、接收键盘事件全都正常。

  为什么唯独输入法整块消失？
]

#lab("实验 3：直接跟 session bus 说 D-Bus 的 SASL 握手")[
  不借助任何 dbus 库，直接连 socket、说协议。libdbus 会替我们算凭据，而我们恰恰要看的就是
  它算出来的那个 uid，跟内核报给 broker 的 uid 是不是同一个。

  ```sh
  # 宿主上（对照组）
  我声称的 uid  = 1000
  AUTH EXTERNAL 31303030
  broker 回答   = OK 141f7f61ac5ca6aa5803b7a99eed73d2

  # 空的 user namespace 里
  我声称的 uid  = 65534
  AUTH EXTERNAL 3635353334
  broker 回答   = REJECTED EXTERNAL
  ```
]

这就是现场。链条是这样的：

- libdbus 用 `getuid()` 拼出它的 `AUTH EXTERNAL` 凭据 —— 在空映射里，那是 65534
- dbus-broker 不在你的 namespace 里，它用 `SO_PEERCRED` 拿内核报的 uid —— 那是 1000
- 两个数对不上，broker 回 `REJECTED`，你没有 session bus

而 fcitx5 就在那条 bus 上：

```sh
$ busctl --user list | grep -i fcitx
org.fcitx.Fcitx5      1322 fcitx5  lenitain  user@1000.service
org.fcitx.Fcitx-0     1322 fcitx5  lenitain  user@1000.service
org.freedesktop.portal.Fcitx  1322 fcitx5  ...
```

session bus 没了，Qt 的输入法模块就够不着 fcitx5。因果链闭合。

= 第三层：为什么只有输入法坏

这是整件事里最值得学的一步。同一个 namespace 里，为什么 D-Bus 断了而别的都没断？

#lab("实验 4：同一个 namespace 里，往 Wayland 合成器发一次真实请求")[
  ```sh
  # 宿主上
  connect(/run/user/1000/wayland-1) 成功 —— 没有交换任何凭据
  合成器回了 2008 字节，前 8 字节 = 0200000000002400

  # 空的 user namespace 里
  connect(/run/user/1000/wayland-1) 成功 —— 没有交换任何凭据
  合成器回了 2008 字节，前 8 字节 = 0200000000002400
  ```

  一模一样的 2008 字节。这不是「只是连上了」，是一次完整的请求-应答。
]

答案在两种通道的差别上：

- *Wayland 是裸 `connect()`。* 连上就是连上了，没有任何一步需要它知道你是谁。
- *D-Bus 要先认证。* 握手的第一件事就是自报身份，而身份这个东西，
  恰好被 user namespace 改掉了。

所以 namespace 打断的不是「所有 IPC」，而是*所有需要身份的 IPC*。浏览器能画能播能收键，
因为那些通道不问你是谁。

#wrong[
  我最初的方向全错了：去查 fcitx5 的配置、查 `QT_IM_MODULE` 有没有传进去、
  查字体、重启输入法。

  这些全都不是原因。真正的原因在*认证层*，而不在输入法本身 —— 输入法只是那个恰好
  需要知道自己是谁的组件。症状出现在最上层，根因在最底层，中间隔了 Wayland、Qt、
  D-Bus 三层。
]

= 第四层：它连本职工作也没做好

到这里还算「用错工具，代价是输入法」。但更尴尬的是，就算你接受全部代价，
它在收尸这件事本身上也不称职。

#lab("实验 5：杀掉 `unshare` 这个 wrapper，namespace 里的进程跟着走吗")[
  ```sh
  wrapper pid = 100735
  namespace 里的 sleep pid = 100737

  $ kill -TERM 100735
    wrapper 状态 = S
    sleep   状态 = S        # 完全没反应

  $ kill -KILL 100735
    wrapper 状态 = 已退出
    sleep   状态 = S        # 孤儿，还活着
  ```

  `S` 是可中断睡眠，也就是正常活着的状态。判活要看 `/proc/<pid>/stat` 的状态字段，
  不能用 `kill -0` —— 僵尸进程对 `kill -0` 仍然返回成功，会把「已死」误报成「还活着」。
]

wrapper 和 namespace init 是*两个进程*，中间没有任何东西转发信号。杀 wrapper 不会
带走里面任何一个。

补丁于是按固定顺序到来：

+ `--kill-child`，让 wrapper 死的时候顺手带走 init
+ 再套一层监督进程，去接 wrapper 从来没收到的 `SIGTERM`
+ `prctl(PR_SET_PDEATHSIG)`，处理监督进程自己的父进程也死了的情况

打到第三个补丁的时候，「简单的 namespace 方案」已经是三个进程深了，而我为生命周期写的代码
比原来的问题本身还多。

= 需求其实是什么

把话重新说一遍。我要的*不是*「围住这棵树」，是两件具体的事：

- 一个 *cgroup* —— 由内核维护的、到时候要扫掉的那个集合
- *主进程跟踪* —— 有东西注意到主进程退出了，不管它是怎么退的

#think[
  这两样东西，你的机器上其实*已经有一个现成的实现*，而且从开机起就在跑。

  是什么？
]

= 我早就有的那个 supervisor

pid 1 —— 也就是 user manager。它管理 cgroup，它跟踪主进程，它在每个用户会话里本来就在跑。

更有意思的是，niri *已经*给每个 `spawn-sh` 建了一个独立的 cgroup，还带着
`KillMode=control-group`。看起来简直就是为了这个需求长的。

但它不行，而且差的那一点正好是关键：

#lab("实验 6：scope 和 service 的 MainPID 有什么不一样")[
  ```sh
  $ systemctl --user show lab-scope-....scope -p MainPID
  MainPID=（空）

  $ systemctl --user show lab-service-....service -p MainPID
  MainPID=100938
  ```

  *scope 的 `MainPID` 是空的。* 它有一个完整的 cgroup，但没有指定任何一个进程是「主进程」。
  既然没有主进程，也就没有谁的死亡可以被注意到。
]

#lab("实验 7：SIGKILL 掉主进程，子进程谁活下来")[
  三种启动方式跑同一棵最小进程树（主进程拉起一个后台子进程），然后 `kill -KILL` 主进程：

  ```sh
  【A】裸 setsid —— 没有 cgroup
    主进程 pid = 100949，子进程 pid = 100951
    => 子进程：存活（S）

  【B】systemd 临时 scope —— 有 cgroup，没有 MainPID
    主进程 pid = 100958，子进程 pid = 100960
    => 子进程：存活（S）

  【C】systemd 临时 service —— 有 cgroup，也有 MainPID
    主进程 pid = 100970，子进程 pid = 100972
    => 子进程：已退出
  ```

  B 和 C 的差别*只有一件事*：这个 cgroup 有没有把某个进程指定为主进程。
  一个有孤儿，一个干干净净。
]

顺带记一个坑，它让这个实验白跑过一轮：payload 不能用 `sh -c '...'` 传进去。
systemd 会对 `ExecStart` 做 `$` 展开，而 `$$` 在那里是「转义成字面美元符」的意思 ——
于是 `echo $$` 到了进程里变成 `echo $`，主进程 pid 根本拿不到，B、C 两档静默地什么都没杀，
实验看起来「跑通了」其实完全无效。放进脚本文件里的 `$$` 不经过 systemd，才是安全的。

= 结论

#quote(block: true)[
  需要生命周期保证的时候，去找那个本来就管着生命周期的东西。
  隔离原语当不好 supervisor。
]

落到我的浏览器上，就是把启动方式从「niri spawn 一个脚本」改成「注册成一个 systemd service」。
保证是 pid1 级的，所以它不依赖浏览器讲道理、不依赖 QtWebEngine 乖乖退出、也不依赖我的
启动脚本转发对了信号。每一条终止路径都收在同一处：

- `systemctl --user stop`
- 对主进程 `kill -9`
- 从浏览器内部退出（`:quit`）
- 注销登录

而且有个反直觉的附带收益：*进程树变小了*。原来的「监督进程 + `unshare` + 浏览器」
变成「浏览器」。一个真实存在的进程，换掉三个专门用来互相管理的进程。

启动脚本现在完全不知道 systemd 的存在。在终端里直接跑它，行为一模一样 ——
只是不会自动收尸。

= 下一章

收尸的人定了，接下来是钱的问题：这个常驻副本到底该占多少内存，哪些字节值得留在 RAM 里，
哪些应该被主动赶回磁盘。

下一章：*什么该留在 RAM*。
