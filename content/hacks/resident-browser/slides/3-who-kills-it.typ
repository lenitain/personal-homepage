#import "../.course.typ": cols, note, punch, slide, title

#set document(title: "谁来释放资源（讲义）")

// 切法跟文档版不同：一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 跑出来的结果不进讲义 —— 讲课的时候当场跑，讲义上只留脚本路径。

#slide[
  #title[谁来释放资源]

  常驻的含义就是*比启动它的东西活得更久* ——
  这正是它的价值所在，也正是问题所在。
]

#slide[
  = 不是关掉一个进程，是释放一整棵树的资源

  一个 qutebrowser 不是一个进程，是五个：本体，加一小群 QtWebEngine 帮手。

  而这件事平时完全看不出来 —— 只有真的注销之后，
  `ps` 里才会出现一堆没有父进程的渲染进程。
]

#slide[
  = 释放资源是个分组问题，不是隔离问题

  #cols[
    *namespace* 来自隔离世界：BSD jails、Solaris zones、docker 容器。

    它回答的是「怎么让一个进程看不见另一个进程」。
  ][
    *cgroup* 来自资源核算世界：统计和限制一组进程用了多少 CPU 和内存。

    它回答的是「怎么把一组进程当成一个整体对待」。
  ]

  「主进程死了，把剩下的一起带走」—— 答案在第二套里。
]

#slide[
  = PID namespace 看起来正好解决这两个问题

  namespace 的 init 一死，内核回收里面所有进程 ——
  隔离和释放资源，一个原语就够了。
]

#slide[
  = 普通人拿不到 PID namespace

  只有 root 能单独建 —— 它在设计上就不是给普通用户做生命周期管理用的，
  是给容器运行时做隔离用的，而容器运行时是 root。

  想走这条路，必须先建一个 user namespace。

  #note[现场跑：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`]
]

#slide[
  = user namespace 的默认状态是「你没有身份」

  空的 user namespace 里，你不是你自己：`getuid()` 拿到的是内核顶上的占位值 65534。

  *要变成你自己，得显式地写一条映射。*

  而「没有身份」对绝大多数程序是无害的 —— 所以这个坑埋得深。

  #note[现场跑：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`]
]

#slide[
  = 代价是输入法整块消失

  页面渲染、滚动、视频、快捷键，全都正常。只有一件事不对：*打不出中文。*

  不是候选词不出来，也不是候选框位置错了 —— 是输入法像根本不存在。
  这个区别决定了你往哪个方向查。
]

#slide[
  = 断的不是所有连接，是所有需要身份的连接

  #cols[
    *Wayland*

    裸 `connect()`。连上就是连上了，
    没有任何一步需要它知道你是谁。
  ][
    *D-Bus*

    要先认证。握手的第一件事就是自报身份，
    而身份恰好被 user namespace 改掉了。
  ]

  #note[现场跑：`./docs/labs/resident-browser/14-identity-channels.sh`]
]

#slide[
  = 它连释放资源这件事本身也没做成

  杀掉 wrapper，namespace 里的进程还活着。

  原因很朴素：wrapper 和 namespace init 是*两个进程*，
  中间没有任何东西转发信号。

  #note[现场跑：`./docs/labs/resident-browser/10-namespace-failure-modes.sh`]
]

#slide[
  = 补丁会一直打下去

  先给 wrapper 加 `--kill-child`（它死时顺手带走 init）→ 再套一层监督进程
  （把收到的信号转发下去）→ 再上 `PR_SET_PDEATHSIG`（父进程死了，子进程跟着死）。

  打到第三个补丁，「简单的 namespace 方案」已经是三个进程深了 ——
  为生命周期写的代码，比原来的问题本身还多。

  #punch[一个错的工具如果当场就报错，你会立刻换一个；它要是能用，你就会一直在它上面打补丁。]
]

#slide[
  = 释放资源需要的东西只有两样

  + 一个 *cgroup* —— 由内核维护的、「到时候要扫掉哪些进程」的那个集合
  + *主进程跟踪* —— 有东西注意到主进程退出了，不管它是怎么退的

  这两样东西，你的机器上已经有一个现成的实现，从开机起就在跑：pid 1。
]

#slide[
  = 看起来最像的那个不行：它没有主进程

  niri 给每个 `spawn-sh` 都建了独立的 cgroup，退出时还会把整组扫干净。
  这简直就是为了这个需求长的。

  但那是 systemd 的 *scope*：只把一组进程圈起来记账，*不会指定谁是主进程*。
  既然没有主进程，就没有谁的死亡可以被注意到。

  #note[现场跑：`./docs/labs/resident-browser/11-cgroup-vs-mainpid.sh`]
]

#slide[
  = 三种启动方式，差别只有一件事

  同一棵进程树、同一个 `SIGKILL`：直接跑有孤儿，scope 有孤儿，
  service（会指定主进程的那种）干干净净。

  差别只有一件事：这个 cgroup 有没有把某个进程指定为主进程。

  #note[现场跑：`./docs/labs/resident-browser/11-cgroup-vs-mainpid.sh`]
]

#slide[
  #punch[
    需要生命周期保证的时候，
    去找那个本来就管着生命周期的工具。

    隔离原语不应用于管理资源的生命周期。
  ]
]
