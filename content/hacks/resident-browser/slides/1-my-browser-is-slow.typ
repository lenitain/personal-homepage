#import "../.course.typ": cols, note, punch, slide, title

#set document(title: "我的 qutebrowser 启动好慢，我该怎么办？（讲义）")

// 这一章是整门课的地基，所以从零开始：
// 读者已知的唯一一件事是「qutebrowser 启动慢」。
// fork、execve、地址空间、ELF、动态链接 —— 全都当没听过，一个一个来。
//
// 标题仍然是关于主题的断言，不是关于这次演讲的元评论。

#slide[
  #title[我的 qutebrowser 启动好慢，我该怎么办？]

  qutebrowser 启动要 1.2 到 1.9 秒。一天开二十次，每次都等这一秒多。

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
  + *其他进程也在用* —— 同一个文件的代码段：两个进程加载同一个库，
    内核不会把它抄两份
  + *谁都没在用* —— 映射了，但还没碰过；碰的那一刻才去磁盘上取

  #note[第二种不需要谁去安排，只要两个进程在同一个库上跑就会发生。但它省下多少是个数，得量。]
]

#slide[
  = 一份 libc，六个进程同时用着

  脚本起六个进程各自 exec 一份同一个 libc，都停在原地，
  再从各自的 `smaps` 里读这个库的账：

  六个进程的 `Rss` 相加 *7.5 MiB*，`Pss` 相加 *0.2 MiB* —— 而库文件本身 2.3 MiB。
  两笔账报的是同一批页，只有一笔是物理内存。

  #punch[回头看 `fork`：写时拷贝复制的是这一堆页表项，不是页表项指向的物理页。]

  #note[现场跑：`./docs/labs/resident-browser/06b-libc-shared.sh`。数字每次动一点，要看的是两笔账差多少倍。]
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
  = 具体看看 qutebrowser 的启动过程

  回到最初的问题：那 1.2 到 1.9 秒花在哪。

  测量 qutebrowser 从 shell 里敲的那个命令，到出现窗口的全部过程。
]

#slide[
  = 一：不是一个二进制

  970 字节的 Python 脚本。

  这直接接上前面：shell 那次 `execve` 交出去的不是可执行程序，
  而是一个 shebang 脚本。内核*不跑这个文件，去找它指定的那个程序* —— 这次是 `python3`。

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
  = 四：把整个启动过程分开看

  给全程打时间戳，找几个*可以外部观测*的界标 —— 敲下命令、
  第一个 Qt 的库被打开、第一次连上合成器。三个时刻一减，
  这一次的 1.81 秒就分成两段了。

  #punch[前 337 毫秒是 Python，后 1472 毫秒是 Qt 和 QtWebEngine。]

  #note[现场跑：`./docs/labs/resident-browser/13-qutebrowser-checkup.sh`]
]

#slide[
  = 那 1472 毫秒具体在干什么

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
  + 它这一次的 1.81 秒 = 337 毫秒 Python + 1472 毫秒 Qt/QtWebEngine

  *还不知道：* 这一秒里有没有哪几段是完全可以共享的。

  #punch[
    每次都相同且和具体任务无关的开销，这是“能不能只付一次”这个问题的起点。
  ]

  这件事是下一章要做的。
]
