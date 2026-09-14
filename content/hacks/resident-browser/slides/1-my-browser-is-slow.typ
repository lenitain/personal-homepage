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
  = 新进程的创建分为两步

  在 Linux 上「跑一个程序」是什么意思？

  现存所有的 Unix 及类 Unix 操作系统内核（Linux、macOS、BSD、Plan 9 …）
  都用相同的方式创建进程：*先复制一个现有的进程，再把复制品的内容换掉。*

  两个步骤对应的系统调用分别是 `fork` 和 `execve`。

  #note[两者都声明在 `<unistd.h>`（POSIX 标准头文件）中]
]

#slide[
  = qutebrowser 启动时做的就是这两步

  `fork` 只复制页表，子进程和父进程共用数据页，写数据时才做局部拷贝(cow)。qutebrowser 启动的开销主要是 `execve`。

  #punch[那 execve 到底要花多少工夫？要看清楚它，得先知道进程「里面」是什么样。]
]

#slide[
  = 一个进程里面的那片「内存」，是虚拟的

  一个运行中的进程，有一片属于它自己的内存，称为*地址空间*。

  从进程的视角看，这是*一整片连续*的地址：从 0 一直增长到极大的数字，
  数组里的元素一个挨着一个，指针加上偏移量就表示连续内存中具体的位置。

  这些编号在 Linux 里可以直接看：`cat /proc/{pid}/maps`。

  #note[进程看见的地址是虚拟内存构建出来的，连续的地址空间实际是将物理内存切成小份再拼凑起来分发给各个进程的，相邻的两个地址落到物理上可能隔着很远。]
]

#slide[
  = 一个地址编号指向的内容有三种情况

  + *只有当前进程在用* —— 刚写进去的变量，刚压进去的栈
  + *其他进程也在用* —— 比如 libc.so，全系统几十个进程共用同一份
  + *谁都没在用* —— 映射了，但还没碰过；碰的那一刻才去磁盘上取

  用一个例子来证明一定存在动态链接库复用机制。

  #punch[回头看 `fork`：写时拷贝复制的是这一堆约定，不是约定指向的物理页。]

  #note[现场跑：`./docs/labs/resident-browser/06-one-copy.sh`]
]

#slide[
  = 映射 1 GiB，物理内存只涨了 0.2 MiB

  「映射」不是「读进来」。它只在页表里写下一句对应关系：
  *这一段地址，内容去磁盘上那个文件的这一段取*。

  所以地址空间涨了 1024 MiB，物理内存基本没动。
  真正把内容取进来，是程序*碰到*那些地址的那一刻 —— *碰多少，涨多少*。

  内核装载可执行文件用的就是这套动作：把 `PT_LOAD` 一段段*登记*进地址空间，然后走人。

  #note[现场跑：`./docs/labs/resident-browser/05-mmap-not-occupied.sh`]
]

#slide[
  = execve 拿到一个文件，怎么把它变成地址空间

  文件自己里面写着安排。这类文件叫 *ELF*，开头有一张表：

  #table(
    columns: (auto, 1fr),
    table.header([表项], [含义]),
    [`PT_LOAD`], [要放进地址空间的一段，自带位置和权限],
    [`PT_INTERP`], [这个文件自己跑不起来，需要解释器],
  )

  内核照着 `PT_LOAD` 一项一项地放。放完，地址空间就成形了。
]

#slide[
  = 加了那一项之后，内核启动的其实不是你的程序

  你用了 `printf()` 这个功能。它不是你的代码，是别人写好的库 ——
  你的程序里只写了「调用它」，于是缺了一块：*它自己跑不起来。*

  办法是在那张表里加一项，写上「我需要一个解释器」。

  内核把地址空间建好之后，*跳转的是那个解释器*，你的程序只是作为参数被交出去。
  它叫*动态链接器*，任务就是补上缺的那一块。

  #note[现场跑：`./docs/labs/resident-browser/07-elf-loading.sh`]
]

#slide[
  = 解释器要做四件事

  + *找库* —— 你的程序说「我要用 libc」，它得去磁盘上找出来
  + *把库映射进地址空间* —— 跟内核刚才做的事一样，这次是给库做
  + *修正地址* —— 程序放在哪是随机的，代码里写死的那些地址得重算一遍
  + *调各家的初始化函数* —— 每个库都可能有「用之前得先准备好」的东西
]

#slide[
  = 这套流程的账单

  同一个 `hello.c` 编两遍：一个自足（静态），一个要用解释器（动态）。
  两个程序都只打印一行字，做的事一模一样。

  #punch[差出来的那一截，就是那一整套：启动解释器、找库、映射进来、重定位、调初始化。]

  #note[现场跑：`./docs/labs/resident-browser/08-dynamic-loader.sh`]
]

#slide[
  = 而且这 156 µs 跟程序要做什么毫无关系

  这两个程序都只打印一行字，但该找的库一个都不能少找，该重定位的一个都不能少算。

  程序越复杂、依赖的库越多，这一段越长。

  qutebrowser 依赖 Qt、QtWebEngine、Python 解释器和它的一大堆模块 ——
  1.2 秒里很大一块是这个。
]

#slide[
  = 具体看看 qutebrowser 的启动过程

  回到最初的问题：那 1.2 秒花在哪。

  测量 qutebrowser 从 shell 里敲的那个命令，到出现窗口的全部过程。
]

#slide[
  = 一：不是一个二进制

  970 字节的 Python 脚本。

  这直接接上前面：shell 那次 `execve` 交出去的不是可执行程序，
  内核要靠 shebang 再转一手 —— 跟 `PT_INTERP` 是同一个思路，
  只不过这次要找的是 `python3`，不是动态链接器。

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 二：一路上 exec 了什么

  ```sh
  $ strace -f -e trace=execve qutebrowser --version
  ```

  连 `--version` 这种「什么都不干」的调用，QtWebEngine 都会先起两个 zygote ——
  它们不是 execve 出来的，是从一个已经装好引擎的模板进程里 fork 出来的。

  #note[这里有个陷阱：不清 PATH 直接跑，trace 里会出现几十条在 mise 各目录试探 uname/file 的记录 —— 全是测量环境的噪声。*测量环境本身也是变量。*]

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 三：Python 侧的开销

  ```sh
  $ python3 -X importtime -c "import qutebrowser.qutebrowser"
  ```

  *一共 109 个模块，光把它们导进来就要 90 毫秒。*

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 四：把整个 1.2 秒分开看

  给全程打时间戳，找几个*可以外部观测*的界标 —— 敲下命令、
  第一个 Qt 的库被打开、第一次连上合成器。三个时刻一减，
  这一秒就分成两段了。

  #punch[前 233 毫秒是 Python，后 1014 毫秒是 Qt 和 QtWebEngine。]

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 那 1014 毫秒具体在干什么

  同一时间窗的系统调用：`openat` 932、`read` 1508、`newfstatat` 1304、`mmap` 1007

  *这是一段大量的小文件操作，不是在算东西。*

  #note[⚠️ 这次 trace 里 QtWebEngineProcess 一次都没出现，而体检二里连 --version 都会起两个。差别在哪还没查清，记在这里而不是猜一个解释。]

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
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
    每次都相同且和具体任务无关的开销，这是“能不能只付一次”这个问题的起点。
  ]

  这件事是下一章要做的。
]
