#import "../.course.typ": cols, note, punch, slide, title

#set document(title: "我的 qutebrowser 启动好慢，我该怎么办？（讲义）")

// 这一章是整门课的地基，所以从零开始：
// 读者已知的唯一一件事是「qutebrowser 启动慢」。
// fork、execve、地址空间、ELF、动态链接 —— 全都当没听过，一个一个来。
//
// 标题仍然是关于主题的断言，不是关于这次演讲的元评论。

#slide[
  #title[我的 qutebrowser 启动好慢，我该怎么办？]

  qutebrowser 启动要 1.2 秒。一天开几十次，每次都等这 1.2 秒。

  *该从哪里入手呢？*
]

#slide[
  = 「启动」是什么意思

  在动手之前，得先弄清楚一个更基础的问题：

  *在 Linux 上「跑一个程序」到底是什么意思？*

  现存所有的 Unix 及类 Unix 操作系统内核 (Linux, MacOS, BSD, Plan9 ...)，都用相同的方式创建进程。
  进程创建的过程是后面所有事情的入口。
]

#slide[
  = 新进程的创建分为两步

  *先复制一个现有的进程，再把复制品的内容换掉。*

  两个步骤对应的系统调用分别是 `fork` 和 `execve`。

  #note[两者都声明在 `<unistd.h>`（POSIX 标准头文件）中]
]

#slide[
  = 新进程的创建被分为两步是刻意的工程设计

  既然要的是「跑一个新程序」，为什么不一步到位？

  比如输入 `echo hello > out.txt` 的时候，shell 并不是「让 echo 去写文件」——
  echo 根本不知道有文件这回事。

  实际情况是 shell `fork` 出自己，子进程「标准输出」改成那个文件后才 `exec` echo。

  #note[这套机制保证了资源的复用。环境变量、标准输出、文件描述符等资源不需要在每个进程创建时额外设置，而是继承自父进程。]
]

#slide[
  = 回到开头：按下回车时 shell 做的就是这两步

  ```sh
  fork()     复制一个自己出来
  execve()   把复制品的内容换成 qutebrowser
  ```

  慢的那一个显然是第二步。`fork` 只是复制一下，很便宜。

  #punch[那 execve 到底要花多少工夫？要看清楚它，得先知道进程「里面」是什么样。]
]

#slide[
  = 一个进程里面，是一片自己的内存

  这片内存叫*地址空间*。

  关键是：它不是一整块，而是一堆区间拼起来的。

  有的区间放代码，有的放数据，有的当栈用。

  想看的话，Linux 直接给你看 —— 下一张。
]

#slide[
  = 一个进程的地址空间长什么样

  ```sh
  $ cat /proc/self/maps
  00400000-00401000 r--p 00000000  …/maps-static
  00401000-0048c000 r-xp 00001000  …/maps-static
  0048c000-004c2000 r--p 0008c000  …/maps-static
  004c2000-004c6000 r--p 000c2000  …/maps-static
  004c6000-004c8000 rw-p 000c6000  …/maps-static
  004c8000-004ce000 rw-p 00000000  [heap]
  7ffd…000-7ffd…000 rw-p 00000000  [stack]
  ```

  每行是一个区间：起止地址、权限（`r--p` 只读、`r-xp` 可执行、`rw-p` 可读写）、
  对应哪个文件。

  #note[`/proc/self/maps` 里的 self 指「读这个文件的那个进程自己」—— 所以这其实是 cat 在念它自己的地址空间。]
]

#slide[
  = execve 拿到一个文件，怎么把它变成地址空间

  文件自己里面写着安排。这类文件叫 *ELF*，开头有一张表：

  #table(
    columns: (auto, 1fr),
    table.header([表项], [含义]),
    [`PT_LOAD`], [要放进地址空间的一段，自带位置和权限],
    [`PT_INTERP`], [这个文件自己跑不起来，需要解释器],
    [`PT_DYNAMIC`], [给链接器看的表],
  )

  内核照着 `PT_LOAD` 一项一项地放。放完，地址空间就成形了。
]

#slide[
  = 表和地址空间能一行行对上

  #cols[
    *文件里的表*
    ```sh
    LOAD 0x400000  R
    LOAD 0x401000  R E
    LOAD 0x48c000  R
    LOAD 0x4c2148  RW
    ```
  ][
    *进程的地址空间*
    ```sh
    00400000-00401000 r--p
    00401000-0048c000 r-xp
    0048c000-004c2000 r--p
    004c2000-004c6000 r--p
    004c6000-004c8000 rw-p
    ```
  ]

  起始地址一样、长度一样、权限一样。

  #note[最后那项在进程里比在文件里大 —— 多出来的是全局变量，初始值全是 0，所以文件里不用存。]
]

#slide[
  = 但现代程序大多不是自足的

  你用了「打印到屏幕」这个功能，它不是你的代码，是别人写好的库。

  你的程序里只写了「调用它」，没把代码抄进来。

  于是这个可执行文件缺了一块 —— *它自己跑不起来。*

  办法是在那张表里加一项，写上「我需要一个解释器」：

  ```sh
  $ readelf -lW hello-dyn | grep -A1 INTERP
    [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  ```
]

#slide[
  = 有那一项的话，内核启动的其实不是你的程序

  它把地址空间建好之后，*跳转的是那个解释器*；
  你的程序只是作为参数被交出去，请解释器把它跑起来。

  那个解释器叫*动态链接器*。它的任务就是补上缺的那一块。

  #note[静态链接的程序没有这一项 —— 文件里什么都有，内核搬完就能跑。]
]

#slide[
  = 解释器要做四件事

  + *找库* —— 你的程序说「我要用 libc」，它得去磁盘上找出来
  + *把库搬进地址空间* —— 跟内核刚才做的事一样，这次是给库做
  + *修正地址* —— 下一张讲
  + *调各家的初始化函数* —— 每个库都可能有「用之前得先准备好」的东西
]

#slide[
  = 为什么地址需要「修正」

  编译的时候，程序是假设自己从某个固定地址开始放的，
  代码里凡是写地址的地方都按那个假设填好了。

  但出于安全考虑，系统每次运行会把程序放在一个*随机*的位置上。

  #punch[位置变了，那些写死的地址就全不对了 —— 得重算一遍。这个重算叫重定位。]
]

#slide[
  = 你的 main 不是第一个跑的东西

  ```sh
  $ LD_DEBUG=libs ./ctor-demo
    find library=libctor.so [0]; searching
      trying file=…/glibc-hwcaps/x86-64-v3/libctor.so
      trying file=…/glibc-hwcaps/x86-64-v2/libctor.so
      trying file=…/libctor.so            ← 逐级回退着找
    calling init: /lib64/ld-linux-x86-64.so.2
    calling init: /usr/lib/libc.so.6
    calling init: …/libctor.so
    initialize program: ./ctor-demo       ← 你自己的 main 排最后
  ```

  每一层都得等下面那层准备好。
]

#slide[
  = 这套流程的账单

  两个程序都只打印一行字：

  #cols[
    *自足的（静态）*
    ```sh
    224 µs
    大部分是 fork + execve 本身
    ```
  ][
    *要用解释器的（动态）*
    ```sh
    505 µs
    多了 281 µs
    ```
  ]

  #punch[那 281 µs，就是上面那一整套：启动解释器、找库、搬进来、重定位、调初始化。]
]

#slide[
  = 而且这 281 µs 跟程序要做什么毫无关系

  这两个程序都只打印一行字，但该找的库一个都不能少找，该重定位的一个都不能少算。

  程序越复杂、依赖的库越多，这一段越长。

  qutebrowser 依赖 Qt、QtWebEngine、Python 解释器和它的一大堆模块 ——
  1.2 秒里很大一块是这个。
]

#slide[
  = 该拿这套机制去量什么了

  回到最初的问题：那 1.2 秒花在哪。

  量的是*普通的 qutebrowser* —— 从 shell 里敲的那个命令。全部外部观测，不动它一行代码。
]

#slide[
  = 体检一：它不是一个二进制

  ```sh
  $ file /usr/bin/qutebrowser
  /usr/bin/qutebrowser: Python script, ASCII text executable
  $ ls -l /usr/bin/qutebrowser
  -rwxr-xr-x 1 root root 970  4月  4 00:40 /usr/bin/qutebrowser
  $ head -1 /usr/bin/qutebrowser
  #!/usr/bin/python3
  ```

  970 字节的 Python 脚本。

  这直接接上前面：shell 那次 `execve` 交出去的不是可执行程序，
  内核要靠 shebang 再转一手 —— 跟 `PT_INTERP` 是同一个思路，
  只不过这次要找的是 `python3`，不是动态链接器。
]

#slide[
  = 体检二：这一路上 exec 了什么

  ```sh
  $ strace -f -e trace=execve qutebrowser --version
  ```

  连 `--version` 这种「什么都不干」的调用，QtWebEngine 都会先起两个 zygote：

  ```sh
  execve("/usr/lib/qt6/QtWebEngineProcess", ["--type=zygote", "--no-zygote-sandbox", …])
  execve("/usr/lib/qt6/QtWebEngineProcess", ["--type=zygote", …])
  ```

  #note[这里有个陷阱：不清 PATH 直接跑，trace 里会出现几十条在 mise 各目录试探 uname/file 的记录 —— 全是测量环境的噪声。*测量环境本身也是变量。*]
]

#slide[
  = 体检三：Python 侧的账单

  ```sh
  $ python3 -X importtime -c "import qutebrowser.qutebrowser"
  ```

  ```sh
  累计      自身      模块
  90.4 ms   0.9 ms   qutebrowser.qutebrowser
  62.9 ms   0.9 ms   qutebrowser.misc.earlyinit
  38.9 ms   2.2 ms   traceback
  28.2 ms  10.4 ms   _colorize          ← 跟浏览器毫无关系
  17.5 ms   0.4 ms   json
  ```

  *一共 109 个模块，光把它们导进来就要 90 毫秒。*
]

#slide[
  = 体检四：把那 1.2 秒切成几段

  给全程打时间戳，找可以外部观测的界标：

  ```sh
  02:36:43.113   0          execve("/usr/bin/qutebrowser")   起点
  02:36:43.346   +233 ms    第一个 libQt6*.so 被打开        Python 阶段结束
  02:36:44.360   +1247 ms   第一次 connect 到 wayland        窗口要出现了
  ```

  #punch[前 233 毫秒是 Python，后 1014 毫秒是 Qt 和 QtWebEngine。]
]

#slide[
  = 那 1014 毫秒具体在干什么

  ```sh
  qutebrowser/qt/webkit.py  (+ .pyc)                ← 导入 QtWebEngine 模块
  /usr/lib/qt6/plugins/platforms/libqwayland.so     ← Qt 装载平台后端
  /usr/lib/libOpenGL.so.0  libharfbuzz  libfreetype  libpng16 …
  /dev/shm/.org.chromium.Chromium.*                 ← Chromium 建共享内存段
  ```

  同一时间窗的系统调用：`openat` 932、`read` 1508、`newfstatat` 1304、`mmap` 1007

  *这是一段大量的小文件操作，不是在算东西。*

  #note[⚠️ 这次 trace 里 QtWebEngineProcess 一次都没出现，而体检二里连 --version 都会起两个。差别在哪还没查清，记在这里而不是猜一个解释。]
]

#slide[
  = 体检到此为止

  细节还能再往下拆（adblock、profile、会话恢复各占多少），但主要开销已经清楚了：

  #punch[
    1.25 秒里，约 90 毫秒是 Python，约 1 秒是 Qt 和 QtWebEngine 的初始化。
  ]
]

#slide[
  = 最有用的一个观察

  为了量这一秒，用的命令是 `qutebrowser -R about:blank` —— *开的是一个空白页*。

  而这一秒照样花了。

  #punch[这一秒发生在「你要求它打开什么」之前。]

  它跟你要访问的网页无关，跟你开几个标签页无关。只要启动，就得付。
]

#slide[
  = 现在知道什么

  *已知：*

  + 一个程序从「文件」变成「跑起来的进程」，中间有一整套固定的流程
  + qutebrowser 是这套流程的一个实例：970 字节的 Python 脚本
  + 它的 1.25 秒 = 233 毫秒 Python + 1014 毫秒 Qt/QtWebEngine
  + 这 1 秒*跟你要打开什么无关* —— 开空白页它照样花

  *还不知道：* 这一秒里有没有哪几段是完全可以共享的。

  #punch[
    一笔每次都一样、而且跟你要做的事无关的开销 ——
    这正是「能不能只付一次」这个问题的起点。
  ]

  这件事是下一章要做的。
]
