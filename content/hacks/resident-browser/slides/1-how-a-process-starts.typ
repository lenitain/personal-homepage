#import "../.course.typ": title, slide, punch, cols, note

#set document(title: "一个进程是怎么起来的（讲义）")

// 幻灯片版。标题都是关于*主题*的断言，不是关于这次演讲的元评论，
// 也不是我的个人状态 —— 只看这一串标题应该能读出完整论证。

#slide[
  #title[一个进程是怎么起来的]

  从敲下回车，到你的代码第一行开始执行

  #note[完整版见 `1-how-a-process-starts.typ`。演示脚本在 `docs/labs/resident-browser/04-06`。]
]

#slide[
  = 这一章要讲的是「前言」这个词到底指什么

  后面几章会反复说「常驻能省下一份前言」「静态链接更快」。

  那些话里的每个名词，都是这一章里的某几步。

  #punch[不先把机制看清楚，那些数字就只是一堆数。]
]

#slide[
  = execve 是替换，不是新建

  当前进程的内存全部丢掉，换成一个新程序。

  内核拿到的是一张*段表*：

  #table(
    columns: (auto, 1fr),
    table.header([段], [含义]),
    [`PT_LOAD`], [要映射进地址空间的段，自带权限],
    [`PT_INTERP`], [这个文件自己跑不起来，需要解释器],
    [`PT_DYNAMIC`], [给链接器看的表],
  )
]

#slide[
  = 内核只做一件事：把 PT_LOAD 逐段 mmap

  地址用段表里写的，权限用段表里写的。做完这些，地址空间就成形了。

  #punch[「地址空间里的那些 VMA」不是抽象概念，就是这些东西。]
]

#slide[
  = 段表和 /proc/self/maps 一一对应

  #cols[
    *段表（readelf -lW）*
    ```sh
    LOAD 0x000000 0x400000 R
    LOAD 0x001000 0x401000 R E
    LOAD 0x08c000 0x48c000 R
    LOAD 0x0c2148 0x4c2148 RW
    ```
  ][
    *地址空间（/proc/self/maps）*
    ```sh
    00400000-00401000 r--p
    00401000-0048c000 r-xp
    0048c000-004c2000 r--p
    004c2000-004c6000 r--p
    004c6000-004c8000 rw-p
    ```
  ]

  起始地址一样、长度一样、权限一样。

  #note[最后那段 RW 在进程里比在文件里大 —— 多出来的是 .bss，文件里不占空间。]
]

#slide[
  = 有 PT_INTERP 的文件，自己跑不起来

  ```sh
  $ readelf -lW hello-dyn | grep -A1 INTERP
    INTERP  …
      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  ```

  内核做完 mmap 之后跳转的*不是*这个程序，而是那个解释器。

  原程序只是作为参数被交出去。
]

#slide[
  = 两个都只打印一行 hello，启动过程完全不同

  ```sh
  # 动态版：execve 之后
  execve("./hello-dyn", …) = 0
  openat("/etc/ld.so.cache") = 3
  mmap(167295, …, 3, 0)
  openat("/usr/lib/libc.so.6") = 3
  mmap(2464592, MAP_PRIVATE|MAP_DENYWRITE, 3, 0)      ┐
  mmap(1769472, …MAP_FIXED, …, 3, 0x24000)            │ libc 的
  mmap( 491520, …MAP_FIXED, …, 3, 0x1d4000)           │ 四个
  mmap(  24576, …MAP_FIXED, …, 3, 0x24c000)           ┘ PT_LOAD
  系统调用总数: 36

  # 静态版：execve 之后
  execve("./hello-static", …) = 0
  arch_prctl(ARCH_SET_FS, …) = 0
  系统调用总数: 19
  ```

  #punch[那四行 mmap 是同一个 fd、MAP_FIXED、四段 —— 链接器在替 libc 做内核刚才做过的事。]
]

#slide[
  = 链接器接着做四件事

  + *找库* —— 读 `/etc/ld.so.cache` 和各库的 `DT_NEEDED`，递归找全
  + *映射* —— 把每个 `.so` 的 `PT_LOAD` 段 mmap 进来
  + *重定位* —— 修正地址
  + *调 init* —— 按依赖顺序调用每个目标文件的初始化函数

  ```sh
  $ LD_DEBUG=statistics ./ctor-demo
    total startup time in dynamic loader: 97452 cycles
    time needed for relocation:            3250 cycles (3.3%)   101 处
    time needed to load objects:          38073 cycles (39.0%)
  ```
]

#slide[
  = 重定位为什么必须做

  程序编译时假设自己从某个固定地址开始，代码和数据里凡是写绝对地址的地方，
  都是按那个假设填的。

  但 ASLR 每次给一个随机基址。

  #punch[所有写死的地址都得重算一遍 —— 这就是重定位。]
]

#slide[
  = 你的 main 不是第一个跑的东西

  ```sh
  $ LD_DEBUG=libs ./ctor-demo
    find library=libctor.so [0]; searching
      trying file=…/glibc-hwcaps/x86-64-v3/libctor.so
      trying file=…/glibc-hwcaps/x86-64-v2/libctor.so
      trying file=…/libctor.so          ← 逐级回退
    calling init: /lib64/ld-linux-x86-64.so.2
    calling init: /usr/lib/libc.so.6
    calling init: …/libctor.so
    initialize program: ./ctor-demo     ← 主程序排最后
  ```

  每一层都依赖下面那层已经就绪，顺序不能颠倒。
]

#slide[
  = 惰性绑定：一个正在消失的机制

  教材里的 PLT：调用外部函数先跳一小段桩代码，桩代码查表，第一次查不到就请链接器解析。

  *今天基本看不到了* —— 发行版默认 `-z now`，启动时一次解析完。
  换来的是延迟可预测，以及完整 RELRO 带来的只读保护。

  但「懒」和「不懒」的差别还能造出来看：
]

#slide[
  = 惰性与全绑的差别：一个永不调用的函数

  ```c
  if (argc > 99) never_called();   /* argc 不可能到 99 */
  called_sometimes();
  ```

  ```sh
  【懒（默认）】    never_called 绑定了几次：0     ← 一次都没解析
  【-z now】        never_called 绑定了几次：1     ← 启动时就解析了
  ```

  所以 `-z now` 不是「删掉 PLT」，是「不再拖到第一次调用才解析」。
]

#slide[
  = 这套流程的账单

  #cols[
    *只 exit_group 的静态二进制*
    ```sh
    224 µs
    地板：fork + execve + wait
    ```
  ][
    *动态 glibc（/bin/true）*
    ```sh
    505 µs
    多了 281 µs
    ```
  ]

  那 281 µs 就是上面那一整套。链接器自己的计算只占几十微秒，
  剩下的是打开并映射那些库，以及随之而来的缺页。
]

#slide[
  = 这套流程跟你的程序要做什么毫无关系

  同样的库、同样的重定位、同样的 init 顺序 ——
  不管你接下来是要打开一个网页还是五十个。

  #punch[既然每次完全一样，那能不能只付一次？]
]

#slide[
  = 能，但前提是不要 exec 一个新进程

  `fork` 出来的子进程拿到一份*已经建好的地址空间*的副本
  （内核用写时复制，并不真的拷内存）。

  库的映射、重定位的结果、构造函数跑完的状态，全都在里面。

  前面那四步，一次都不用再做。
]

#slide[
  = fork 继承 vs exec 重来：差 9.9 倍

  造一个「很贵」的库（构造函数里初始化 8 MB 数据段），两条路各派生 40 次：

  ```sh
  A）zygote：父进程加载一次，之后全靠 fork
      构造函数跑了几遍: 1        总耗时:  19 ms

  B）exec：每次 exec 一个全新进程
      构造函数跑了几遍: 40       总耗时: 188 ms
  ```
]

#slide[
  = 真实系统里的样子：zygote

  ```sh
  $ （列出所有 QtWebEngineProcess：pid / 父进程 / 类型）
    1633    1357    zygote
    1634    1357    zygote
    1636    1634    zygote      ← 父进程是另一个 zygote
    1689    1636    renderer    ← 父进程是 zygote
    6151    1636    renderer
    112935  1636    renderer
  ```

  每个渲染器都从「渲染器模板」fork 出来 ——
  打开一个新标签页不需要重新建立那一千多个映射。
]

#slide[
  = 证据不只是父子关系，还有地址空间本身

  #cols[
    *zygote*
    ```sh
    1222 个 VMA
    RSS 65 MB
    ```
  ][
    *renderer*
    ```sh
    1358 个 VMA
    RSS 152 MB
    ```
  ]

  两者映射的共享库列表*完全一致* —— renderer 一个共享库都没自己加载。

  #note[多出来的 RSS 是跑起来之后的堆和 JIT 代码，不是加载新库的开销。]
]

#slide[
  #punch[
    一个开销能不能提前付，
    看的是有没有一条进程边界，
    让贵的那部分跨多次使用共享。
  ]

  下一章：这条结论落到一个具体问题上 —— 什么样的程序值得为它常驻。
]
