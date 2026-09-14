#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "谁来释放资源")

#title[谁来释放资源]

上一章让浏览器变成了一个常驻进程。这一章要还的，是那笔当场欠下的账。

常驻的含义就是*比启动它的东西活得更久* —— 这正是它的价值所在，也正是问题所在。
一个 qutebrowser 不是一个进程，是五个：本体，加一小群 QtWebEngine 帮手，
其中一个是 Chromium 的 renderer，占着几百兆内存。
所以你欠的不是「关掉一个进程」，是*释放一整棵树的资源*。

这件事平时完全看不出来。开发的时候反复启动、反复关窗，一切正常；
只有真的注销之后，`ps` 里才会出现一堆没有爹的 renderer —— 而那时候你已经在做别的事了。

= 1. 释放资源是个分组问题，不是隔离问题

Linux 这块地上住着两套互不相干的东西，而它们经常被当成一套来用。

第一套是 *namespace*，来自隔离世界 —— BSD jails、Solaris zones、后来演变成容器的那条线。
它回答的问题是：*怎么让一个进程看不见另一个进程？*
挂载点、PID、网络、主机名、用户，各自有一层 namespace 可以把它们切开。

第二套是 *cgroup*，来自资源核算世界 —— 最初是为了统计和限制一组进程用了多少 CPU 和内存。
它回答的问题正好是另一个：*怎么把一组进程当成一个整体来对待？*

释放资源这件事 —— 「主进程死了，怎么把剩下的一起带走」—— 是一个*分组*问题，
答案应该在第二套里。但字面上看，「PID namespace 的 init 一死，内核回收整个 namespace」
实在太像答案了：它确实是一个「一组进程一起走」的机制。我第一反应就去拿了它。

== 走错的方式值得记下来

不是「不知道有 cgroup」。是*一个机制顺手能解决你的问题时，你不会去问它原本是干什么用的*。

而代价通常不在你验证过的那条路径上，而在旁边某条你根本没意识到的路径上。

= 2. 第一步就走不通

`unshare --pid --fork`，把整棵树关进去：namespace 的 init 一死，内核回收里面所有进程。
隔离和释放资源一次搞定，一个原语解决两个问题。看起来非常干净。

#ask[
  这个方案有什么问题？

  「它不管用」不是答案 —— 它管用。
  一个错的工具如果当场就报错，你会立刻换一个；它要是能用，你就会一直在它上面打补丁。
]

#lab("演示 10：非特权用户能单独建一个 PID namespace 吗")[
  ```sh
  三条实跑（都不需要 root）：
  unshare --pid --fork --mount-proc true   → unshare: unshare 失败: 不允许的操作（退出码 1）
  ```

  普通用户拿不到 PID namespace，只有 root 可以 —— 它在设计上就不是给普通用户
  做生命周期管理用的，是给容器运行时做隔离用的，而容器运行时是 root。

  （完整脚本：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`）
]

想走这条路的普通人，*必须先用 `--user` 建一个 user namespace*。而那个 user namespace，
就是后面所有麻烦的源头。

= 3. user namespace 的默认状态是「你没有身份」

#lab("演示 10：建了 user namespace 之后，你的 uid 是什么")[
  ```sh
  unshare --user --pid ... sh -c 'id -u'   → 65534   宿主上的 uid 是 1000；uid_map 是空的，65534 是内核的 overflow uid
  unshare --user --map-current-user ...    → 1000   uid 映射对了（1000 1000 1），可 D-Bus 认的是凭据上的那一个
  ```

  建一个空的 user namespace，你并不是以你自己的身份进去的：`uid_map` 是空的，
  `getuid()` 拿不到你的 uid，内核拿 overflow uid 顶上 —— 65534。
  要变成你，得显式地写一条映射。

  （完整脚本：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`）
]

#note[
  `--map-current-user` 这个选项本身就说明问题：一个*隔离*工具默认不给你身份，
  你得额外请求「顺便把我也映进去」。
]

而「没有身份」这件事，对绝大多数程序是无害的。这就是这个坑埋得深的地方：
它不影响渲染、不影响滚动、不影响键盘输入。

= 4. 代价：按身份认人的通道全部断掉

补上 `--map-current-user` 之后，浏览器一切正常。页面渲染、滚动、视频、快捷键，全都对。

只有一件事不对：*打不出中文。*

不是候选词不出来，也不是候选框位置错了 —— 是输入法像根本不存在。
「转换不出来」和「根本没接上」是两类完全不同的故障。

原因在认证层。输入法住在 session bus 上，而 D-Bus 的握手第一件事就是自报身份。

我没有继续猜，而是把握手协议自己说了一遍 —— 不借助任何库，直接连 socket、发字节。
因为 libdbus 会替你把凭据算好，而要看的就是*它算出来的那个 uid，
跟内核报给 broker 的 uid 是不是同一个*。

#lab("演示 14：同一个 namespace 里，D-Bus 断了、Wayland 没断")[
  ```sh
  $ ./14-identity-channels.sh
    uid：宿主上 1000；空的 namespace 里 65534（uid_map 是空的，内核拿 overflow uid 顶上）

    D-Bus —— 先认证，第一句话就是自报身份
      宿主上          声称 1000，AUTH EXTERNAL 31303030    → OK 82905cdad8870b558b87afde0d204fcb
      空的 namespace  声称 65534，AUTH EXTERNAL 3635353334 → REJECTED EXTERNAL

    Wayland —— 裸 connect，连上就说，没有一步问你是谁
      宿主上          connect 成功，要回 registry，2032 字节
      空的 namespace  connect 成功，要回 registry，2032 字节
  ```

  同一个动作，两条通道两个结果。`OK` 后面那串是 broker 自己的 GUID
  （它每次重启都会变），要看的是 `OK` 和 `REJECTED` 这两个词。

  链条到这里闭合了：

  +   libdbus 用 `getuid()` 拼出 `AUTH EXTERNAL` 凭据 —— 在空映射里，那是 65534
  +   dbus-broker *不在你的 namespace 里*，它用 `SO_PEERCRED` 拿内核报的 uid —— 那是 1000
  +   两个数对不上，broker 回 `REJECTED`，你没有 session bus

  fcitx5 就在那条 bus 上，于是 Qt 的输入法模块够不着它，整块功能消失。

  （完整脚本：`./docs/labs/resident-browser/14-identity-channels.sh`）
]

== 断的不是所有 IPC，是所有需要身份的 IPC

两条通道的差别不在连接层 —— 两条都连上了。差别在*认证*：

#cols[
  *Wayland*
  ```sh
  connect() 成功
  没有交换任何凭据
  ```
][
  *D-Bus*
  ```sh
  要先认证
  握手第一件事是自报身份
  ```
]

Wayland 是裸 `connect()` —— 连上就是连上了，没有任何一步需要它知道你是谁。
D-Bus 要先认证，而身份恰好被 user namespace 改掉了。

所以同一棵树里，浏览器能画、能播、能收键，输入法却整块消失。

#oops[
  我最初查的是 fcitx5 的配置、`QT_IM_MODULE` 有没有传进去、字体、重启输入法。

  全都不是原因。真正的原因在*认证层*，而输入法只是那个恰好需要知道自己是谁的组件。
  症状出现在最上层，根因在最底层，中间隔了 Wayland、Qt、D-Bus 三层。
]

= 5. 它连释放资源这件事本身也没做成

到这里还算「用错工具，代价是输入法」。但就算你接受全部代价，它在*释放资源*上也不称职。

#lab("演示 10：杀掉 `unshare` 这个 wrapper，里面的进程会怎样")[
  ```sh
  kill -TERM wrapper   → wrapper 状态 S，sleep 状态 S（还活着）
  kill -KILL wrapper   → wrapper 状态 已退出，sleep 状态 S（还活着）
  ```

  `S` 是可中断睡眠，也就是正常活着的状态。

  原因很朴素：wrapper 和 namespace init 是*两个进程*，中间没有任何东西转发信号。

  （完整脚本：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`）
]

#note[
  判活要看 `/proc/<pid>/stat` 的状态字段，*不能用 `kill -0`*。僵尸进程对 `kill -0`
  仍然返回成功，会把「已死」误报成「还活着」—— 这个坑让我的第一个版本的实验
  得出了相反的错误结论。
]

于是补丁按固定顺序到来：先加 `--kill-child`，让 wrapper 死的时候顺手带走 init；
然后发现 wrapper 自己收到的 `SIGTERM` 根本没往下传，于是套一层监督进程去接；
再然后发现监督进程的父进程死了它也活不下来，于是上 `prctl(PR_SET_PDEATHSIG)`。

打到第三个补丁的时候，「简单的 namespace 方案」已经是三个进程深了。
*我为生命周期写的代码，比原来的问题本身还多。*

= 6. 把需求重新说一遍，要的东西只有两样

丢掉所有实现细节，我要的其实是两件具体的事：

+   一个 *cgroup* —— 由内核维护的、「到时候要扫掉哪些进程」的那个集合
+   *主进程跟踪* —— 有东西注意到主进程退出了，不管它是怎么退的

这两样东西，机器上已经有一个现成的实现，而且从开机起就在跑：pid 1，也就是 user manager。
它管理 cgroup，它跟踪主进程，它在每个用户会话里本来就在跑 ——
只是你平时不觉得那是「一个 supervisor」。

== 但看起来最像的那个东西不行

我的窗口管理器 niri 给每个 `spawn-sh` 都建了独立的 cgroup，还带着 `KillMode=control-group`。
这简直就是为了这个需求长的。但它差了关键的一点：

#lab("演示 11：scope 和 service 的 MainPID")[
  ```sh
  同一个命令，两种 systemd 用法，各建出一个 cgroup：
    --scope   lab-scope-255409.scope   MainPID （空）
    --unit    lab-service-255409.service   MainPID 255514
  ```

  *scope 的 `MainPID` 是空的。* 它有一个完整的 cgroup，但没有指定任何一个进程是「主进程」。
  既然没有主进程，也就*没有谁的死亡可以被注意到* —— scope 要等到 cgroup 自己空了
  才算 inactive，而「cgroup 空掉」正是你希望它去*造成*的那个事件。

  （完整脚本：`./docs/labs/resident-browser/11-cgroup-vs-mainpid.sh`）
]

= 7. 三种启动方式，差别只有一件事

同一棵最小进程树 —— 一个主进程，加一个它拉起的子进程 —— 三种启动方式：

#lab("演示 11：杀掉主进程之后，子进程还在不在")[
  ```sh
  同一棵进程树（主进程 + 一个它拉起的子进程），SIGKILL 掉主进程之后：
    A  裸 setsid            没有 cgroup              子进程 存活（S）
    B  systemd 临时 scope   有 cgroup，MainPID 空    子进程 存活（S）
    C  systemd 临时 service 有 cgroup，MainPID 有    子进程 已退出
  ```

  B 和 C 的差别*只有一件事*：这个 cgroup 有没有把某个进程指定为主进程。
  一个有孤儿，一个干干净净。

  最容易看走眼的是 B：`systemd-cgls` 看过去和 C 一模一样，可它不负责释放资源。
  「有个容器把它装着」和「有人知道谁是主进程」是两件事，保证来自后者。

  （完整脚本：`./docs/labs/resident-browser/11-cgroup-vs-mainpid.sh`）
]

#oops(label: "⚠️ 一个让实验白跑一轮的坑")[
  payload 不能用 `sh -c '...'` 传进去。systemd 会对 `ExecStart` 做 `$` 展开，
  而 `$$` 在那里是「转义成字面美元符」的意思 —— 于是 `echo $$` 到了进程里变成 `echo $`，
  主进程 pid 根本拿不到。

  结果 B、C 两档*静默地什么都没杀*，而实验看起来「跑通了」。

  放进脚本文件里的 `$$` 不经过 systemd，才是安全的。这个 bug 的危险之处不是它错了，
  是它错得跟你期望的一致。
]

= 8. 结论

#punch[
  需要生命周期保证的时候，去找那个本来就管着生命周期的东西。
  隔离原语当不好 supervisor。
]

落到浏览器上，就是把启动方式从「niri spawn 一个脚本」改成「注册成一个 systemd service」。
保证是 *pid1 级*的：不依赖浏览器讲道理、不依赖 QtWebEngine 乖乖退出、
也不依赖启动脚本转发对了信号。每一条终止路径都收在同一处 ——
`systemctl --user stop`、对主进程 `kill -9`、从浏览器内部退出、注销登录。

== 附带收益：进程树变小了

原来的「监督进程 + `unshare` + 浏览器」变成「浏览器」——
一个真实存在的进程，换掉三个专门用来互相管理的进程。

而启动脚本现在完全不知道 systemd 的存在。在终端里直接跑它，行为一模一样，
只是主进程退出时，没人替你释放剩下的资源。

== 下一章：什么该留在 RAM

释放资源的人定了，接下来是开销的问题。
