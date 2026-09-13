#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "谁来收尸")

#title[谁来收尸]

上一章把浏览器变成了一个常驻进程。这一章要还的，是那笔当场欠下的账。

常驻的含义就是*比启动它的东西活得更久* —— 这正是它的价值所在，也正是问题所在。
一个 qutebrowser 不是一个进程，是五个：本体，加一小群 QtWebEngine 帮手，
其中一个是 Chromium 的 renderer，占着几百兆内存也照样心安理得。所以你欠的不是
「关掉一个进程」，是*收一整棵树的尸*。

而这件事有个很坏的性质：它平时完全看不出来。开发的时候你反复启动、反复关窗，
一切正常；只有当你真的注销、或者哪个进程意外崩掉之后，
才会在 `ps` 里看见一堆没有爹的 renderer 还在那儿。

= 1. 两个不同的问题，被同一套工具回答了

要理解我为什么会走错路，得先看清楚 Linux 这块地上其实住着*两套互不相干的东西*，
而它们经常被当成一套来用。

第一套是 *namespace*。它来自隔离世界 —— BSD jails、Solaris zones、
后来演变成容器的那条线。它要回答的问题是：*「怎么让一个进程看不见另一个进程？」*
挂载点、PID、网络、主机名、用户，各自有一层 namespace 可以把它们切开。

第二套是 *cgroup*。它来自资源核算世界 —— 最初是为了「怎么统计和限制一组进程
用了多少 CPU 和内存」。它要回答的问题是：*「怎么把一组进程当成一个整体来对待？」*

现在把收尸这件事放进来：*「主进程死了，怎么把剩下的一起带走？」*

这是一个*分组*问题，不是隔离问题。答案应该在第二套里。但字面上看，
「PID namespace 的 init 一死，内核回收整个 namespace」这句话实在太像答案了 ——
它确实是一个「一组进程一起走」的机制。我第一反应就去拿了它。

== 这就是这一章要讲的错

不是「我不知道有 cgroup」。是*一个机制顺手能解决你的问题时，你不会去问它原本是干什么用的。*
而代价通常不在你验证过的那条路径上，而在旁边某条你根本没意识到的路径上。

= 2. 我的第一反应

`unshare --pid --fork`，把整棵树关进去。namespace 的 init 一死，内核回收里面所有进程 ——
隔离和收尸一次搞定，一个原语解决两个问题。看起来非常干净。

#ask[
  这个方案有什么问题？

  先自己回答一句再往下看。答案*不是*「它不管用」—— 恰恰相反，它管用。
  这才是陷阱：一个错的工具如果当场就报错，你会立刻换一个；
  它要是能用，你就会一直在它上面打补丁。
]

= 3. 第一层：它根本没打算做这件事

#lab("实验：非特权用户能单独创建 PID namespace 吗")[
  ```sh
  $ unshare --pid --fork --mount-proc true
  unshare: unshare 失败: 不允许的操作
  ```
]

退出码 1。普通用户拿不到 PID namespace，只有 root 可以 —— 因为 PID namespace 在设计上
就不是给普通用户做生命周期管理用的，它是给容器运行时做隔离用的，而容器运行时是 root。

所以想走这条路的普通人，*必须先用 `--user` 建一个 user namespace*。
而那个 user namespace，就是后面所有麻烦的源头。

#lab("实验：那先建 user namespace，uid 会变成什么")[
  ```sh
  $ unshare --user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"
  65534
  (↑ getuid，↓ uid_map —— 空的)
  ```

  加上 `--map-current-user` 才会把你映进去：

  ```sh
  $ unshare --user --map-current-user --pid --fork --mount-proc sh -c "id -u; cat /proc/self/uid_map"
  1000
        1000       1000          1
  ```
]

这里有个反直觉的地方值得停一下：*user namespace 的默认状态是「你没有身份」，
不是「你还是你」。* 建一个空的 user namespace，你并不是以你自己的身份进去的 ——
`uid_map` 是空的，`getuid()` 拿不到你的 uid，内核拿 overflow uid 顶上，也就是 65534。
要变成你，得显式地写一条映射。

而「没有身份」这件事，对绝大多数程序是无害的。这就是为什么这个坑埋得深：
它不影响渲染、不影响滚动、不影响键盘输入。

#note[
  顺便说一句，`--map-current-user` 这个选项本身就说明问题：一个*隔离*工具
  默认不给你身份，你得额外请求「顺便把我也映进去」。它的作者没打算让你在这儿过日子。
]

= 4. 第二层：输入法是怎么死的

补上 `--map-current-user` 之后，浏览器一切正常。页面渲染、滚动、视频、快捷键，全都对。

只有一件事不对：*打不出中文。*

不是候选词不出来，也不是候选框位置错了 —— 是输入法像根本不存在。
这个区别很重要，因为「转换不出来」和「根本没接上」是两类完全不同的故障，
而我按前一类查了很久。

#ask[
  同一个 namespace 里，渲染页面、播放视频、接收键盘事件全都正常。

  *为什么唯独输入法整块消失？*
]

我没有继续猜，而是直接把 D-Bus 的握手协议自己说了一遍 —— 不借助任何 dbus 库，
直接连 socket、发字节。因为 libdbus 会替我们算凭据，而我要看的恰恰就是
*它算出来的那个 uid，跟内核报给 broker 的 uid 是不是同一个*。

#lab("实验：直接跟 session bus 说 D-Bus 的 SASL 握手")[
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

链条到这里就闭合了：

+   libdbus 用 `getuid()` 拼出 `AUTH EXTERNAL` 凭据 —— 在空映射里，那是 65534
+   dbus-broker *不在你的 namespace 里*，它用 `SO_PEERCRED` 拿内核报的 uid —— 那是 1000
+   两个数对不上，broker 回 `REJECTED`，你没有 session bus

而 fcitx5 就在那条 bus 上：

```sh
$ busctl --user list | grep -i fcitx
org.fcitx.Fcitx5               1322 fcitx5  lenitain  user@1000.service
org.fcitx.Fcitx-0              1322 fcitx5  lenitain  user@1000.service
org.freedesktop.portal.Fcitx   1322 fcitx5  lenitain  user@1000.service
```

session bus 没了，Qt 的输入法模块就够不着 fcitx5。整块功能消失。

== 为什么只有输入法坏

这才是整件事里最值得学的一步。同一个 namespace 里，为什么 D-Bus 断了而别的都没断？

答案在两种通道的差别上。我往 Wayland 合成器上发了一次*真实的请求-应答*
（不是「连一下试试」，是真的要一份 registry 回来）：

#cols[
  *宿主上*
  ```sh
  connect(/run/user/1000/wayland-1) 成功
  —— 没有交换任何凭据
  合成器回了 2008 字节
  ```
][
  *空的 user namespace 里*
  ```sh
  connect(/run/user/1000/wayland-1) 成功
  —— 没有交换任何凭据
  合成器回了 2008 字节
  ```
]

一模一样的 2008 字节。而差别是：

-   *Wayland 是裸 `connect()`* —— 连上就是连上了，没有任何一步需要它知道你是谁
-   *D-Bus 要先认证* —— 握手的第一件事就是自报身份，而身份恰好被 user namespace 改掉了

所以 namespace 打断的不是「所有 IPC」，而是*所有需要身份的 IPC*。
浏览器能画能播能收键，因为那些通道不问你是谁。

#oops[
  我最初查的是 fcitx5 的配置、`QT_IM_MODULE` 有没有传进去、字体、重启输入法。

  全都不是原因。真正的原因在*认证层*，而输入法只是那个恰好需要知道自己是谁的组件。
  症状出现在最上层，根因在最底层，中间隔了 Wayland、Qt、D-Bus 三层 ——
  这就是为什么「顺着症状往下找」在这类 bug 上会失效。
]

= 5. 第三层：它连本职工作也没做好

到这里还算「用错工具，代价是输入法」。但更尴尬的是：就算你接受全部代价，
它在*收尸*这件事本身上也不称职。

#lab("实验：杀掉 `unshare` 这个 wrapper")[
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
]

`S` 是可中断睡眠，也就是正常活着的状态。

#note[
  判活要看 `/proc/<pid>/stat` 的状态字段，*不能用 `kill -0`*。僵尸进程对 `kill -0`
  仍然返回成功，会把「已死」误报成「还活着」—— 这个坑让我的第一个版本的实验
  得出了相反的错误结论。
]

原因很朴素：wrapper 和 namespace init 是*两个进程*，中间没有任何东西转发信号。

于是补丁按固定顺序到来。先加 `--kill-child`，让 wrapper 死的时候顺手带走 init；
然后发现 wrapper 自己收到的 `SIGTERM` 根本没往下传，于是套一层监督进程去接；
再然后发现监督进程的父进程死了它也活不下来，于是上 `prctl(PR_SET_PDEATHSIG)`。

打到第三个补丁的时候，「简单的 namespace 方案」已经是三个进程深了。
*我为生命周期写的代码，比原来的问题本身还多。*

= 6. 把需求重新说一遍

丢掉所有实现细节，我要的其实只有两件具体的事：

+   一个 *cgroup* —— 由内核维护的、「到时候要扫掉哪些进程」的那个集合
+   *主进程跟踪* —— 有东西注意到主进程退出了，不管它是怎么退的

#ask[
  这两样东西，你的机器上其实*已经有一个现成的实现*，而且从开机起就在跑。

  是什么？
]

pid 1，也就是 user manager。它管理 cgroup，它跟踪主进程，它在每个用户会话里
本来就在跑 —— 而且它已经这样跑了几十年，只是你平时不觉得那是「一个 supervisor」。

== 但 niri 看起来也很接近，而且它不行

我的窗口管理器 niri 给每个 `spawn-sh` 都建了独立的 cgroup，还带着 `KillMode=control-group`。
这简直就是为了这个需求长的。但它差了关键的一点：

#lab("实验：scope 和 service 的 MainPID")[
  ```sh
  $ systemctl --user show lab-scope-....scope -p MainPID
  MainPID=（空）

  $ systemctl --user show lab-service-....service -p MainPID
  MainPID=100938
  ```
]

*scope 的 `MainPID` 是空的。* 它有一个完整的 cgroup，但没有指定任何一个进程是「主进程」。
既然没有主进程，也就*没有谁的死亡可以被注意到* —— scope 要等到 cgroup 自己空了
才算 inactive，而「cgroup 空掉」正是你希望它去*造成*的那个事件。

换成 service 就好了。三种启动方式跑同一棵最小进程树的对比：

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

#oops(label: "⚠️ 一个让实验白跑一轮的坑")[
  payload 不能用 `sh -c '...'` 传进去。systemd 会对 `ExecStart` 做 `$` 展开，
  而 `$$` 在那里是「转义成字面美元符」的意思 —— 于是 `echo $$` 到了进程里变成 `echo $`，
  主进程 pid 根本拿不到。

  结果 B、C 两档*静默地什么都没杀*，而实验看起来「跑通了」。

  放进脚本文件里的 `$$` 不经过 systemd，才是安全的。这个 bug 的危险之处不是它错了，
  是它错得跟你期望的一致。
]

= 7. 结论

#punch[
  需要生命周期保证的时候，去找那个本来就管着生命周期的东西。
  隔离原语当不好 supervisor。
]

落到我的浏览器上，就是把启动方式从「niri spawn 一个脚本」改成「注册成一个 systemd service」。
保证是 *pid1 级*的，所以它不依赖浏览器讲道理、不依赖 QtWebEngine 乖乖退出、
也不依赖我的启动脚本转发对了信号。每一条终止路径都收在同一处：
`systemctl --user stop`、对主进程 `kill -9`、从浏览器内部退出、注销登录。

== 一个反直觉的附带收益

*进程树变小了。* 原来的「监督进程 + `unshare` + 浏览器」变成「浏览器」——
一个真实存在的进程，换掉三个专门用来互相管理的进程。

而启动脚本现在完全不知道 systemd 的存在。在终端里直接跑它，行为一模一样，
只是不会自动收尸。

== 下一章：什么该留在 RAM

收尸的人定了，接下来是钱的问题。
