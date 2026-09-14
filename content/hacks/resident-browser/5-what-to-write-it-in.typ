#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "快路径用什么写")

#title[快路径用什么写]

启动器只做三件事：找一个 socket，写大约一百个字节，退出。

程序里的工作量小到可以忽略，于是这个实验测的其实是另一件事：
*在某门语言里「成为一个进程」要花多少代价。* 这个量平时观测不到，
因为它总被程序真正在干的事情盖住 —— 只有把程序本身剥到接近零，它才露出来。

所以下面比的不是「哪门语言好」，而是每门语言在你的代码跑起来之前做了什么。

= 1. 方法

== 正确性给基准把关

每一个实现都必须跟已发布的 C 版吐出*逐字节相同*的 IPC 消息，覆盖八个用例：
两个参数、无参数、空参数、引号与反斜杠、换行与制表符、C0 控制字符、裸 UTF-8、
2000 字节的长参数。九个实现全部通过。

一个因为发错字节而变快的启动器，不是启动器。

#lab("演示：九个实现，八个用例，逐字节对比（verify.sh）")[
  ```sh
  variant                     two-args          no-args           empty-arg         quotes-backslash  newline-tab       control-chars     raw-utf8          long-arg
  qb-open-asm                 PASS              PASS              PASS              PASS              PASS              PASS              PASS              PASS
  …                           （八个用例 × 九种实现，全是 PASS，中间七行略）
  qb-open-zig                 PASS              PASS              PASS              PASS              PASS              PASS              PASS              PASS

  ALL VARIANTS MATCH THE REFERENCE
  ```

  （完整脚本：`./docs/labs/resident-browser/verify.sh`）
]

== 延迟

`fork` → `execve` → 干活 → 被回收，用一个 C 写的小工具拿 `clock_gettime` 夹住 `wait4`
来计时。三轮 × 500 次，绑在同一个核上，报三轮*最小值的中位数*。

#note[
  为什么要报最小值？因为这台机器上开着桌面会话，中位数里混着别人的调度。
  最小值是受干扰最少的那一次，它最接近真实开销。绑核也是同一个理由 ——
  不绑核的话，同一份代码的读数能差一半，我第一次测出来的结果就是废的。
]

== 一个「底噪」二进制

一个静态二进制，函数体只有 `exit_group`。它什么都不干，所以它测出来的就是
*每一个实现都要付的「被启动」的开销*。

没有它，「三百微秒」这个数没法解释 —— 你不知道那里面有多少是程序，
有多少只是 fork 和 exec。

== 系统调用与地址空间

系统调用来自 `strace`。地址空间来自 `execve` 成功那一刻的 `ptrace` 停点 ——
在程序执行第一条指令之前：加载器已经干完了，程序还没开始。

#note[
  为什么不直接读 `/proc/<pid>/maps`？因为那是个只活零点几毫秒的进程，
  你轮询不到它。要么让内核把你拦住（ptrace），要么就只能猜。
]

= 2. 延迟

#lab("演示：十一个二进制，三轮 × 500 次，绑核报最小值（latency.sh）")[
  ```sh
  floor (只 fork+exec+wait，程序本身只 exit):
    floor-exit                 min=138.8     p50=143.6     p90=163.6
  对照组:
    /bin/true (dynamic glibc)  min=470.0     p50=503.8     p90=664.1
  launcher 变体:
    qb-open-asm                min=309.9     p50=349.2     p90=480.2
    qb-open-c-musl-static      min=377.6     p50=427.7     p90=553.9
    qb-open-c-glibc-static     min=427.7     p50=491.8     p90=671.8
    qb-open-c-musl-dyn         min=441.5     p50=503.2     p90=684.2
    qb-open-zig                min=459.5     p50=530.8     p90=684.9
    qb-open-rust-static        min=511.9     p50=587.9     p90=759.4
    qb-open-c-glibc-dyn        min=588.1     p50=679.3     p90=867.4
    qb-open-rust-dyn           min=744.2     p50=861.1     p90=980.2
    qb-open-python             min=22741.0   p50=23543.1   p90=24923.4
  ```

  单位微秒。原输出按名字排，这里按最小值重排，行本身没动。

  （完整脚本：`./docs/labs/resident-browser/latency.sh`）
]

== 程序本身的工作量：171 微秒

汇编减底噪：309.9 − 138.8。找一个 socket、写一条消息、退出 —— 这就是全部工作。

在这个尺度上，它相对「存在的代价」是个舍入误差。那条线以上的部分，
*全是语言的运行时在你的代码跑起来之前做的事*。

#punch[
  为一个热路径启动器选语言，不是在选语法或者表达力，
  而是在选「什么东西会跟着你一起启动」。
]

== 跟着一起启动的，是动态链接器

一个可执行文件如果用了别人写好的库（`printf()` 之类），它自己就跑不起来：
文件开头有一张表，其中一项写着「我需要一个解释器」。内核把地址空间建好之后，
*跳转的不是这个程序，而是那个解释器*；原程序只是作为参数被交出去。

那个解释器叫*动态链接器*（`ld.so`）。它每启动一个程序都要做四件事：

+   *找库* —— 程序说「我要用 libc」，它得去磁盘上把 libc 找出来
+   *把库映射进地址空间* —— 跟内核做的事一样，只不过这次是给库做的
+   *修正地址* —— 库被放在哪是随机的，代码里写死的那些地址得重算一遍（叫*重定位*）
+   *调用各家的初始化函数* —— 每个库都可能有「用之前得先准备好」的东西

四件事都是*每次启动重来一遍*，而且跟程序要做什么无关。glibc 自带开关，能把账打出来：

#lab("演示 08：动态链接器每次启动都要做的四件事")[
  ```sh
  $ LD_DEBUG=libs ./ctor-demo
    find library=libctor.so [0]; searching
    trying file=glibc-hwcaps/x86-64-v3/libctor.so
    trying file=glibc-hwcaps/x86-64-v2/libctor.so
    trying file=libctor.so
    calling init: /lib64/ld-linux-x86-64.so.2
    calling init: /usr/lib/libc.so.6
    calling init: libctor.so
    initialize program: ./ctor-demo

  $ LD_DEBUG=statistics ./ctor-demo
    total startup time in dynamic loader: 95205 cycles
    time needed for relocation: 1577 cycles (3.4%)
    time needed to load objects: 37497 cycles (38.4%)
  ```

  找库不是查一次表，是按层级逐级回退着试（那三行 `trying file=`）；
  初始化按依赖顺序来，你自己的 `main` 排在最后。四件事里最贵的是映射各 `.so`，
  但它只是 mmap 登记，不是把内容读进内存。

  #note[
    `LD_DEBUG=statistics` 的 cycle 数每次跑都不一样 —— 同一台机器上，
    链接器的总时间在六万到十万之间跳，百分比也跟着跳。稳定的是另外两件：
    找库试了几个地方，以及初始化的顺序。
  ]

  （完整脚本：`./docs/labs/resident-browser/08-dynamic-loader.sh`）
]

代价可以直接量：同一个 `hello.c` 编两遍，一个自足、一个要用解释器，
两个程序都只打印一行字、做的事一模一样。

#lab("演示 07：同一份源码，静态和动态差多少")[
  ```sh
  同一个 hello.c 编两份，文件里各自都是 4 段（R / R E / R / RW）：
  hello-dyn     地址空间 25 行 = 段表 4 行 + 别人给的 21 行
  hello-static  地址空间 12 行 = 段表 4 行 + 内核给的 8 行
  …
  这用在哪：两个都只打印一行字的程序各跑 400 次，静态 372 µs、动态 495 µs ——
  多出来的 123 µs 全是链接器的活（找库、映射、重定位、调 init），跟程序要做什么毫无关系。
  ```

  静态版短掉的那 21 行，正是 `libc.so.6`、`ld-linux-x86-64.so.2` 这一堆 ——
  这个文件的段表里一个字都没写。

  #note[
    这两个数每次跑都会动几十微秒，差值也跟着动（一百多微秒那个量级不变）。
    机器上还开着桌面会话，这类绝对数只能当量级看。
  ]

  （完整脚本：`./docs/labs/resident-browser/07-elf-loading.sh`）
]

== 静态链接在每一组对比里都赢

#cols[
  *动态*
  ```sh
  C, musl     441.5
  C, glibc    588.1
  Rust        744.2
  ```
][
  *静态*
  ```sh
  C, musl     377.6
  C, glibc    427.7
  Rust        511.9
  ```
]

三比零 —— 动态版本多付的那一截，就是上面那四件事。
这一点在系统调用记录里也看得清楚：同样一份 `qb-open.c`，动态版 42 次调用，静态版 25 次。
多出来的 17 次里，有 8 次 `mmap`，其余是在库缓存里翻找的 `openat` / `newfstatat` / `fstat`。

但静态不是免费的，它是*预付*的：

#lab("演示：九个实现各自的体积（build-all.sh）")[
  ```sh
    ok   qb-open-asm                as-built=11248     stripped=8856
    ok   qb-open-c-musl-static      as-built=53408     stripped=46264
    ok   qb-open-c-musl-dyn         as-built=16208     stripped=14192
    ok   qb-open-c-glibc-static     as-built=907576    stripped=825640
    ok   qb-open-c-glibc-dyn        as-built=17112     stripped=14632
    ok   qb-open-rust-dyn           as-built=394192    stripped=394184
    ok   qb-open-rust-static        as-built=1351504   stripped=1351504
    ok   qb-open-zig                as-built=9008      stripped=7896
    ok   qb-open-python             as-built=2315      stripped=2315
  ```

  同样是 glibc：静态版 *826 KB*，动态版 *15 KB* —— 56 倍的字节，换 160 微秒。
  而 musl 静态只要 *46 KB*，速度还更快。

  （完整脚本：`./docs/labs/resident-browser/build-all.sh`）
]

体积不只是磁盘。映射的地址空间也差得很远：`execve` 之后那一刻，
glibc 静态版已经映射了 1 MB，而 musl 静态版只有 236 KB ——
这个数在同一份测量的 `vma_kb` 那一列里。

= 3. 每个运行时都写在系统调用记录和地址空间里

#lab("演示：execve 成功那一刻的地址空间，和一整轮的系统调用（measure.sh）")[
  ```sh
  qb-open-asm                  p50=766.4     syscalls=10    vma=9    rss=12
  qb-open-c-glibc-dyn          p50=1266.8    syscalls=42    vma=15   rss=20
  qb-open-c-glibc-static       p50=979.5     syscalls=25    vma=10   rss=20
  qb-open-c-musl-dyn           p50=1194.8    syscalls=20    vma=15   rss=20
  qb-open-c-musl-static        p50=543.4     syscalls=20    vma=10   rss=16
  qb-open-python               p50=26133.0   syscalls=867   vma=14   rss=20
  qb-open-rust-dyn             p50=1845.2    syscalls=76    vma=14   rss=24
  qb-open-rust-static          p50=1123.9    syscalls=48    vma=10   rss=24
  qb-open-zig                  p50=1033.6    syscalls=15    vma=9    rss=12
  ```

  `vma` 是 `execve` 之后地址空间里的区间数，`rss` 是那一刻的常驻内存（KB）。

  #note[
    这一节的 `p50` 比上一节大了一倍多 —— 因为它没有绑核。同一个二进制，
    绑不绑核差别就有这么大，所以延迟结论只看上一节。
  ]

  （完整脚本：`./docs/labs/resident-browser/measure.sh`）
]

这组记录把「运行时」这个词变得具体 —— 你能直接看出每门语言在启动时都在忙什么：

-   *汇编* —— 10 个，而且正好就是那件工作：`openat`、`getdents64`、`socket`、
    `connect`、`getcwd`、`write`、`close`、`exit`。没有别的
-   *Zig* —— 15 个，含 `sigaltstack` 和 `prlimit64`。有一点运行时，不多
-   *C，musl，静态* —— 20 个。多出来的 10 个是 libc 在初始化（`brk`、`mmap`、
    `set_tid_address`）
-   *C，glibc，动态* —— 42 个，被 `ld.so` 映射和 stat 库文件占满
-   *Rust，静态* —— 48 个：六个 `rt_sigaction`、五个 `brk`、三个 `mprotect`
-   *Python* —— 867 个，形状就是导入机制：138 次 `newfstatat`、101 次 `read`、
    69 次 `openat`、69 次 `fstat`、62 次 `lseek`。另有 149 次 `clock_gettime`，
    那是 Python 在给自己的导入计时

== Zig 的进程跟手写汇编一样轻

Zig 落在 *9 个 VMA、12 KB RSS*，跟手写汇编*完全一样*，系统调用 15 对 10。
没有运行时需要初始化。这门语言编译出来的东西跟汇编是同类的，
而这在进程本身上直接体现出来 —— 不需要看代码，看 `/proc` 就知道。

== Rust 的启动开销来自 `std`

即使 strip 过，静态 Rust 还是 1.35 MB 和 48 个系统调用，其中六个 `rt_sigaction`、
五个 `brk`。那是 `std` 在你的 `main` 之前搭运行时 —— 而这里 `main` 干的事，
是往一个 socket 写一百个字节。

绝大部分二进制和绝大部分系统调用，都是这个程序*从来不会用到的机器*。

= 4. Python 是汇编版的 73 倍

值得拆开看，因为「Python 慢」这句话本身没有信息量：

#lab("演示：一次加一个 import，看每一段各花多少（python-split.sh）")[
  ```sh
  python3 -c pass                      min=10917.7    (+0.0)
  python3 -c import os                 min=10912.6    (+-5.1)
  python3 -c import socket             min=14956.2    (+4038.5)
  python3 -c import json               min=19537.7    (+8620.0)
  python3 -c import json,socket        min=21931.2    (+11013.5)
  qb-open.py (full)                    min=22670.7    (+11753.0)
  ```

  单位微秒。`os` 那一行是负的 —— 差值在噪声以内，说明这个模块本来就在解释器启动路径上。

  （完整脚本：`./docs/labs/resident-browser/python-split.sh`）
]

解释器本身 10.9 ms。导入两个标准库模块花 11.0 ms —— *比解释器还多*，
而 `json` 一个就顶两个 `socket`。程序真正干的活 —— 扫一个目录、拼一个小对象、
写进 socket —— 只花 *0.7 ms*。

#punch[
  大约 3% 的运行时间是程序被写出来要做的那件事。

  剩下 97% 是可以避免的 ——
  这就是当初值得为它写一个 C 客户端的全部理由，从来不是因为 C 快。
]

#note[
  这张表来自它自己那一轮测量，跟第 2 节那张延迟表里的 22.7 ms 几乎一样，
  剩下的是同一台机器上不同轮次的正常噪声。*比值才是要看的东西*，绝对值不可比。
]

#ask[
  如果你只需要「快」，汇编比 C 版快 68 微秒、小 37 KB。

  这 68 微秒值 400 行手写汇编吗？
]

= 5. 我最后选了什么

*C，musl，静态。* 46 KB，377.6 微秒，20 个系统调用，没有动态加载器，
整个构建是一条 `musl-gcc -static` 命令。

剩下那几个实现存在，是因为我想让这个对比诚实，不是因为维护它们是件好事。

排名的一句话总结：汇编比 C 版小 37 KB、快 68 微秒，代价是 400 行手写汇编去换。
Zig 能用一门你真写得动的语言拿到汇编的进程像，如果从零开始我会选它 ——
代价是把构建钉死在某个具体的 Zig 版本上，而对这么小的一个程序来说，
这个代价换不过一个几十年都稳定的编译器。

= 6. 写五个实现，抓出一个真 bug

这一段不是设计出来的，是写第二份实现的时候撞出来的。

== 原因

C 版用 `snprintf` 拼 JSON，然后把返回值加进写入偏移量。而 `snprintf` 返回的是
它*本应写入*的长度 —— 一旦发生截断，这个偏移量就跳过了 8192 字节缓冲区的末尾，
紧接着 `sizeof(buf) - pos` 下溢成 `SIZE_MAX`，再下一次写入就落到了数组外面，
落在跟 `environ` 同一片 `.bss` 区域里。

== 后果不是理论上的

#lab("演示：同一个启动器，参数从 8000 走到 8300（overflow-check.sh）")[
  ```sh
  n        rc    bytes_sent   fallback_trace
  8000     0     8149         -
  8042     0     8191         -
  8043     0     8192         -
  8044     0     0            execve envp=0x7fffa02ccb90
  8050     0     0            execve envp=0x7fff2c8f1d70
  8100     0     0            execve envp=0x7ffc5b873830
  8300     0     0            execve envp=0x7fff53598930

  边界        最后一个还能发出去的长度 —— 8043 字节（socket 收到 8192 字节，rc=0）
  第一个兜底  从 8044 起，trace 里多出一条 execve —— 它悄悄换了个浏览器起来
  退出码      整张表里出现过 0 —— 从头到尾没有一行在报错
  ```

  越界之后它不崩溃、不报错，而是*行为变了*：快路径发不出去，于是走 fallback，
  冷启动一整个真浏览器。用户看到的现象是「怎么突然变慢了」。

  触发条件是一个大约 8 KB 的参数 —— 在这条路径上，那就是一个很长的 URL。

  （完整脚本：`./docs/labs/resident-browser/overflow-check.sh`）
]

#note[
  ⚠️ 这个脚本*必须*在私有 mount namespace 里跑，它把 `/bin/true` 绑到
  `/usr/bin/qutebrowser` 上再跑。

  因为如果越界写出来的字节恰好构成一个合法的指针数组，`execve` 是*能成功的* ——
  那就真的会拉起用户的浏览器。这个安全网不是谨慎，是这个 bug 的失败模式决定的。
]

== 这个 bug 为什么之前没被发现

每一个其它语言的移植版本*从一开始就做了边界检查*。这是这个差异唯一浮出水面的原因 ——
如果我只写了 C 一版，它会一直躺在那里，因为没有任何东西会去质疑一段「一直能用」的代码。

修法是加一个小 `literal_append` 辅助函数，跟转义函数共用一个容量上限，
于是没有任何一次追加能把偏移量推出末尾。

#oops[
  我原本以为这次多语言实现的价值在于那张对比表 —— 一次纯粹的教学演示。

  实际价值最高的是它顺手抓出来的那个 bug：一个已经发布、每天都在用的内存越界写。

  *多个独立实现是很好的测试套件。* 这一点我原来没预料到。
]

= 7. 结论

#punch[
  对一个热路径上的程序，你不是在选一门语言。
  你是在选「在你的代码跑起来之前，有什么必须启动」—— 而答案是：全部。
]
