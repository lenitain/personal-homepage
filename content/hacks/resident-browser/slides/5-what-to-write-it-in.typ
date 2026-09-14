#import "../.course.typ": note, punch, slide, title

#set document(title: "快路径用什么写（讲义）")

// 切法跟文档版不同：一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 跑出来的结果不进讲义 —— 讲课的时候当场跑，讲义上只留脚本路径。

#slide[
  #title[热路径用什么写]

  常驻的部分（服务端）和它的代价（内存）都说完了。

  剩下那条*热路径* —— 每次按下快捷键都要走一遍的那条：
  从敲下命令、到消息送达之间，那几百微秒是怎么花掉的。
]

#slide[
  = 启动器只做三件事

  找到特定的 socket 文件，写大约一百个字节，退出。

  程序里的工作量小到可以忽略 —— 于是剥掉它之后，
  剩下的是*在某门语言里「成为一个进程」的代价*。
]

#slide[
  = 程序真正干的活只有大约 171 微秒

  汇编版减掉那个只 `exit_group` 的底噪二进制，剩下的就是全部工作：
  找 socket、写一条消息、退出。

  在这个尺度上，它相对「存在的代价」是个舍入误差。

  #note[现场跑：`./docs/labs/resident-browser/latency.sh out 3 500`]
]

#slide[
  #punch[
    为一个热路径启动器选语言，不是在选语法或者表达力，
    而是在选「什么东西会跟着你一起启动」。
  ]
]

#slide[
  = 跟着一起启动的，是动态链接器

  用了别人写好的库的程序，文件里写着「我需要一个解释器」——
  内核建好地址空间之后，*跳转的是那个解释器*，原程序只是作为参数被交出去。

  它每启动一个程序都要做四件事：找库、把库映射进地址空间、修正地址、调各家的初始化函数。
  四件事都跟你程序做什么无关。

  #note[现场跑：`./docs/labs/resident-browser/08-dynamic-loader.sh`]
]

#slide[
  = 同一份源码，静态和动态差 138 微秒

  两个都只打印一行字的程序各跑 400 次：静态 381 µs，动态 519 µs。

  差出来的那一截全是链接器的活。而且它跟程序要做什么无关 ——
  程序只调了一个函数，该找的库一个都不能少找。

  #note[现场跑：`./docs/labs/resident-browser/07-elf-loading.sh`]
]

#slide[
  = 静态链接在每一组对比里都赢

  同样一份 `qb-open.c`：动态版 42 次系统调用，静态版 25 次 ——
  多出来的 17 次里，8 次是 `mmap`（映射内存），其余是在库缓存里翻找。

  #note[现场跑：`./docs/labs/resident-browser/latency.sh out 3 500`]
]

#slide[
  = 静态是预付的：826 KB 换 160 微秒

  C 的标准库有两个实现：glibc（默认那个，大）和 musl（小）。
  同样是 glibc：静态版 826 KB，动态版 15 KB —— 56 倍的字节换 160 微秒。

  体积不只是磁盘：`execve` 之后那一刻，glibc 静态版已经映射了 1 MB。

  #note[现场跑：`./docs/labs/resident-browser/build-all.sh`]
]

#slide[
  = Zig 的进程跟手写汇编一样轻

  *地址空间里 9 个区间、启动那一刻常驻内存 12 KB*，
  跟手写汇编完全一样，系统调用 15 对 10。

  没有运行时需要初始化 —— 这一点不需要看代码，看 `/proc` 就知道。

  #note[现场跑：`./docs/labs/resident-browser/measure.sh out 1000`]
]

#slide[
  = Rust 的启动开销来自标准库

  即使 strip 过，静态版还是 1.35 MB 和 48 个系统调用，
  其中六个 `rt_sigaction`（装信号处理）、五个 `brk`（要内存）。

  那是 Rust 的标准库（`std`）在你的 `main` 之前搭运行时 ——
  而这里 `main` 做的事，是往一个 socket 写一百个字节。

  #note[现场跑：`./docs/labs/resident-browser/measure.sh out 1000`]
]

#slide[
  = Python 是汇编版的 73 倍

  #punch[
    大约 3% 的运行时间是程序被写出来要做的那件事。
    这就是当初值得写一个 C 客户端的全部理由 —— 从来不是因为 C 快。
  ]

  #note[现场跑：`./docs/labs/resident-browser/python-split.sh`]
]

#slide[
  = 解释器本身 10.9 毫秒，导入两个模块 11.0 毫秒

  导入比解释器还贵。而程序真正干的活 —— 扫一个目录、拼一个小对象、
  写进 socket —— 只花 0.7 毫秒。

  每个运行时都写在系统调用记录里：汇编 10 个，musl 静态 20 个，
  Zig 15 个，Rust 静态 48 个，glibc 动态 42 个，Python 867 个。
]

#slide[
  = 选 C，musl，静态

  *46 KB，377.6 微秒，20 个系统调用*，
  整个构建是一条 `musl-gcc -static` 命令。

  汇编小 37 KB、快 68 微秒，代价是 400 行手写汇编。
]
