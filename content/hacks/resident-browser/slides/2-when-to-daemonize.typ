#import "../.course.typ": note, punch, slide, title

#set document(title: "什么样的程序值得常驻（讲义）")

// 切法跟文档版不同：一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 跑出来的结果不进讲义 —— 讲课的时候当场跑，讲义上只留脚本路径。
// 标题是关于主题的断言，不是关于我自己的叙事。

#slide[
  #title[什么样的程序值得常驻]

  序把那 1.2–1.7 秒切成了两段，两段都跟要打开的页面无关。

  *那么，这两段能不能只付一次？*
]

#slide[
  = 常驻是一笔内存交易，不是提速技巧

  启动开销并没有被删掉，只是被一次付清，并且之后也会一直占据存储资源。
]

#slide[
  = 这个思路有四十年历史

  - inetd —— 按需拉起网络服务，然后把连接交给它
  - Emacs server —— 编辑器太贵，常驻一个
  - systemd socket activation —— init 先拿着 socket
  - Ghostty —— 同样的模式，但用 dbus 替换了 socket

  #note[https://ghostty.org/docs/linux/systemd]
]

#slide[
  = 慢的那部分能不能跟请求拆开

  #punch[
    存不存在一大块工作，它在程序知道你想要什么*之前*就做完了，
    而且*每一次都产出完全相同的结果*？
  ]
]

#slide[
  = 浏览器有可切的前言，编译器没有

  *浏览器* —— 解释器、Qt、Chromium 引擎、adblock 规则、profile。
  接下来要开一个标签页还是五十个，这些完全一样。

  *编译器* —— 时间花在读源码、产出二进制上。
  程序运行结果完全取决于输入，输入没有确定这些工作没法开始。

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 前言可以只付一次

  让一个进程先把库加载好，之后每个新任务从它 `fork` ——
  新进程拿到的是那份已经建好的地址空间，加载和初始化一件都不用重做。

  同一个「贵」库、同样 40 次任务：fork 20 毫秒，每次 `exec` 一个新进程 192 毫秒。

  #note[现场跑：`./docs/labs/resident-browser/09-zygote-prefork.sh`]
]

#slide[
  = 零窗口常驻的开销是一百多兆

  零窗口 = 引擎已经装好，一个页面都没开 —— 这是「一直活着」本身的底价。

  #note[现场跑：`./docs/labs/resident-browser/12-resident-memory.sh`]
]

#slide[
  = 常驻进程是「启动那一刻的配置」的快照

  此后每一次改配置，都需要重启守护进程。

  因此需要设计干净地释放常驻进程占据的资源的方式。
]

#slide[
  #punch[
    给「开销恒定且重复」的那部分做常驻。
    凡是取决于请求的东西，让它该多慢就多慢。
  ]

  对浏览器来说，这条线落在*引擎和窗口之间*。
]
