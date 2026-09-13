#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "一个进程是怎么起来的")

#title[我的 qutebrowser 启动好慢，我该怎么办？]

qutebrowser 启动要 1.2 秒。一天开几十次，每次都等这 1.2 秒。

*该从哪里入手呢？*

= 1. 让我们看看一个进程的启动过程吧

== 「启动」是什么意思

在动手之前，得先弄清楚一个更基础的问题：
*在 Linux 上「跑一个程序」到底是什么意思？*

现存所有的 Unix 及类 Unix 操作系统内核（Linux、macOS、BSD、Plan 9 …），
都用相同的方式创建进程。进程创建的过程是后面所有事情的入口。

=== 它不是一步，是两步

如果你没想过这件事，直觉大概是这样：敲一个命令，系统就新建一个进程去跑它。一步。

实际是两步：*先复制一个现有的进程，再把复制品的内容换掉。*

第一步叫 `fork`，第二步叫 `execve`。名字不用记，看它们做什么就行。

=== 第一步：复制

#lab("演示 01：fork 把一个进程变成两个")[
  ```c
  printf("fork 之前：pid = %d\n", getpid());
  pid_t pid = fork();          /* 这一行之后，代码在两个进程里同时往下走 */

  if (pid == 0)      printf("  [子进程] pid = %d\n", getpid());
  else             { printf("  [父进程] pid = %d\n", getpid()); wait(NULL); }
  ```

  ```sh
  $ ./forkonly
  fork 之前：我是一个进程，pid = 135280
    [子进程] 我是复制出来的那一份，pid = 135281，我的父进程是 135280
    [父进程] 我还在，pid = 135280，我复制出来的那个是 135281
  ```

  `fork` 只调用了一次，但它下面的代码*两个进程各跑了一遍*。
  两个进程唯一的区别是 pid。`fork` 的返回值就是用来区分的：
  子进程拿到 0，父进程拿到子进程的 pid。

  （完整脚本：`docs/labs/resident-browser/01-process-creation.sh`）
]

=== 第二步：换内容

复制出来的那份，内容跟原来一模一样 —— 它还是 shell。所以还有第二步：
把这个进程的内容，换成你真正想跑的那个程序。

#lab("演示 01：execve 换掉内容，但不换进程")[
  让子进程先把自己的 pid 写进环境变量，再换成 `/bin/sh`，让 sh 把它打出来：

  ```sh
  $ ./pidcheck
    [sh 说] 我是 pid 135297
    [父进程] 我 fork 出来的 pid = 135297
  ```

  *两个 pid 一样。* 这就是关键：`execve` 不产生新进程，
  它只是把同一个进程里装的东西换掉。pid 不变，进程在系统里的身份也不变。

  换成 `/bin/sh` 之前它是那个小程序，换完之后它是 sh —— 但始终是同一个进程。
]

=== 为什么要分成两步

一个很自然的问题是：既然要的是「跑一个新程序」，为什么不一步到位？

因为*中间那一步有用*。

#lab("演示 01：shell 的重定向就是这么实现的")[
  ```c
  pid_t pid = fork();
  if (pid == 0) {
      int fd = open("out.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
      dup2(fd, STDOUT_FILENO);   /* 让「标准输出」指向那个文件 */
      close(fd);
      execl("/bin/echo", "echo", "这行字会进文件，不会出现在屏幕上", (char *)0);
  }
  ```

  ```sh
  $ ./redir
    （屏幕上什么都没有，对吧？）
    文件里现在写的是：这行字会进文件，不会出现在屏幕上
  ```

  你敲 `echo hello > out.txt` 的时候，shell 并不是「让 echo 去写文件」——
  echo 根本不知道有文件这回事。实际发生的是：

  +   shell `fork` 出自己
  +   子进程把「标准输出」改成那个文件
  +   然后才 `exec` echo

  管道（`|`）是同一个套路，只是把「指向文件」换成「指向另一个进程」。

  所以 `fork` 和 `exec` 分成两步不是历史的偶然，是*故意留出中间那一步* ——
  留给你在「换内容」之前，先把环境布置好。
]

=== 回到我们的问题

你在 shell 里敲下 `qutebrowser` 回车，shell 做的事就是：

```sh
fork()     复制一个自己出来
execve()   把复制品的内容换成 qutebrowser
```

所以「启动一个程序」不是一个动作，是两个。而慢的那一个显然是第二步 ——
`fork` 只是复制一下，很便宜（后面会看到它便宜到什么程度）。

那么 `execve` 到底要花多少工夫？为什么换个程序会有快有慢？

要看清楚它，得先知道一个进程「里面」是什么样子。

== 一个进程里面有什么

一个运行中的进程，有一片属于它自己的内存。这片内存叫*地址空间*。

关键是：*它不是一整块，而是一堆区间拼起来的。* 有的区间放代码，有的放数据，
有的当栈用。想看的话，Linux 直接给你看：

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

每一行是一个区间：起始地址、结束地址、权限（`r--p` 只读、`r-xp` 可执行、`rw-p` 可读写）、
以及它对应哪个文件。

#note[
  `/proc/self/maps` 里的 `self` 指的是「读这个文件的那个进程自己」——
  所以上面这段其实就是 `cat` 在念它自己的地址空间。
]

现在有了「地址空间」这个概念，就可以回答上一节留下的问题了。

== execve 拿到一个文件，怎么把它变成地址空间

`execve` 的输入是一个可执行文件。它要做的，是把这个文件的内容，
按照某种安排放进新建的地址空间里。

安排写在哪里？写在文件自己里面。这类文件叫 *ELF*，它开头有一张表，
每一项描述「我有一段东西，请放到地址空间的某个位置，权限是这样」：

#table(
  columns: (auto, 1fr),
  table.header([表项], [含义]),
  [`PT_LOAD`], [要放进地址空间的一段，自带位置和权限],
  [`PT_INTERP`], [这个文件自己跑不起来，需要先请一个解释器（下一节讲）],
  [`PT_DYNAMIC`], [给链接器看的一张表（再下一节讲）],
)

内核照着 `PT_LOAD` 一项一项地放。放完之后，地址空间就成形了。

#lab("演示 02：表和地址空间摆在一起看")[
  ```sh
  $ readelf -lW hello-static | grep -E 'Type|LOAD'
    Type   VirtAddr           FileSiz  MemSiz   Flg
    LOAD   0x0000000000400000 0x000500 0x000500 R
    LOAD   0x0000000000401000 0x08a7e5 0x08a7e5 R E
    LOAD   0x000000000048c000 0x0352d0 0x0352d0 R
    LOAD   0x00000000004c2148 0x0058e0 0x00b1c0 RW
  ```

  ```sh
  $ cat /proc/self/maps
  00400000-00401000 r--p   ← 对应第 1 项
  00401000-0048c000 r-xp   ← 对应第 2 项
  0048c000-004c2000 r--p   ← 对应第 3 项
  004c2000-004c6000 r--p   ┐
  004c6000-004c8000 rw-p   ┘ 第 4 项（被分成了两行，见下）
  ```

  起始地址一样、长度一样、权限一样（`R` 对应 `r--p`，`R E` 对应 `r-xp`，
  `RW` 对应 `rw-p`）。*四行表对应地址空间里的四段，能一行行数出来。*

  最后那一项有点特别：`MemSiz`（在进程里占 0xb1c0）比 `FileSiz`（文件里占 0x58e0）大。
  多出来的部分在文件里没有内容，但在进程里要占位置 —— 那是全局变量用的地方，
  初始值全是 0，所以文件里不用存。

  （完整脚本：`docs/labs/resident-browser/02-elf-loading.sh`）
]

到这里，一个「自足的」程序就起来了：文件里什么都有，内核照着搬完就能跑。

但现代程序大多不是自足的。

== 很多程序自己跑不起来

你写一个程序，要用到「打印到屏幕」这个功能。这个功能不是你写的，是别人写好的，
放在一个叫「库」的文件里。你的程序只写了「调用它」，没有把它的代码抄进来。

于是你的可执行文件里就缺了一块 —— 它自己跑不起来。

怎么办？在那张表里加一项，写上「我需要一个解释器」：

```sh
$ readelf -lW hello-static | grep -A1 INTERP
（没有这一项，这个文件是自足的）

$ readelf -lW hello-dyn | grep -A1 INTERP
  INTERP  …
      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
```

内核看到这一项之后，行为变了一点：它把地址空间建好之后，*跳转的不是这个程序，
而是那个解释器*；原程序只是作为参数被交出去，请解释器把它跑起来。

那个解释器叫*动态链接器*。它的任务就是补上缺的那一块。

== 解释器做什么

它的工作可以拆成四件事：

+   *找库* —— 你的程序说「我要用 libc」，它得去磁盘上把 libc 找出来
+   *把库搬进地址空间* —— 跟第 3 节内核做的事一样，只不过这次是给库做的
+   *修正地址* —— 这一件最反直觉，下面单独说
+   *调用各家的初始化函数* —— 每个库都可能有「用之前得先准备好」的东西

第三件事值得停下来说清楚：*为什么地址需要「修正」？*

程序在编译的时候，是假设自己从某个固定地址开始放的。代码里凡是需要写地址的地方，
都按那个假设填好了。但出于安全考虑（防止攻击者猜地址），系统每次运行都会把程序
放在一个*随机*的位置上。位置变了，那些写死的地址就全不对了，得重算一遍。

这个重算就叫*重定位*。

#lab("演示 03：把解释器的工作打出来看")[
  glibc 自带几个开关，能把它每一步都打出来：

  ```sh
  # 找库：注意它在按几个层级逐级回退着找
  $ LD_DEBUG=libs ./ctor-demo
    find library=libctor.so [0]; searching
      trying file=…/glibc-hwcaps/x86-64-v3/libctor.so
      trying file=…/glibc-hwcaps/x86-64-v2/libctor.so
      trying file=…/libctor.so
    find library=libc.so.6 [0]; searching
      trying file=/usr/lib/libc.so.6

  # 调初始化：顺序就是依赖顺序，你自己的 main 排最后
    calling init: /lib64/ld-linux-x86-64.so.2
    calling init: /usr/lib/libc.so.6
    calling init: …/libctor.so
    initialize program: ./ctor-demo

  # 账单
  $ LD_DEBUG=statistics ./ctor-demo
    total startup time in dynamic loader: 97452 cycles
    time needed for relocation:            3250 cycles (3.3%)   101 处
    time needed to load objects:          38073 cycles (39.0%)
  ```

  `calling init` 那四行是本节的要点：*你的 `main` 不是第一个跑的东西。*
  解释器自己排最前，然后是 libc，然后是你依赖的库，最后才轮到主程序。
  每一层都得等下面那层准备好 —— 顺序不能颠倒。

  （完整脚本：`docs/labs/resident-browser/03-dynamic-loader.sh`）
]

== 这套流程要花多少钱

上面那一整套流程要花多少时间？先看一个最小的例子：两个程序都只打印一行字，
一个静态链接（自足，前面「execve 拿到一个文件」那节的路），
一个动态链接（要用解释器，后面两节的路）：

#cols[
  *自足的（静态）*
  ```sh
  224 µs
  （这里面绝大部分是
    fork + execve 本身）
  ```
][
  *要用解释器的（动态）*
  ```sh
  505 µs
  （多了 281 µs）
  ```
]

#punch[
  那多出来的 281 µs，就是第 4、5 节里那一整套：
  启动解释器、找库、把库搬进地址空间、重定位、调初始化。
]

而且注意：这 281 µs 跟程序要做什么*毫无关系*。这两个程序都只打印一行字，
但该找的库一个都不能少找，该重定位的一个都不能少算。

一个程序越复杂，依赖的库越多，这一段就越长。qutebrowser 依赖 Qt、QtWebEngine、
Python 解释器和它的一大堆模块 —— 1.2 秒里，很大一块是这个。

#note[
  这里还有个细节值得知道：把库「搬进地址空间」这个动作，本身只是登记一下
  「这段内存对应磁盘上那个文件的这一部分」。真正把内容从磁盘读进来，
  是等程序访问到那段内存时才发生的（叫缺页）。
  所以映射一百个库和真的读一百个库，代价差很远。
]

= 2. 用这套机制给 qutebrowser 做体检

现在手里有工具了。回到最初的问题：那 1.2 秒花在哪。

体检的对象就是*普通的 qutebrowser* —— 从 shell 里敲的那个命令，不带任何修饰。
全部只用外部观测，不动它一行代码。

== 体检一：它到底是什么

```sh
$ file /usr/bin/qutebrowser
/usr/bin/qutebrowser: Python script, ASCII text executable
$ ls -l /usr/bin/qutebrowser
-rwxr-xr-x 1 root root 970  4月  4 00:40 /usr/bin/qutebrowser
$ head -2 /usr/bin/qutebrowser
#!/usr/bin/python3
# EASY-INSTALL-ENTRY-SCRIPT: 'qutebrowser==3.7.0','gui_scripts','qutebrowser'
```

*它不是一个二进制，是一个 970 字节的 Python 脚本。*

这件事直接接上第 1 节：shell 那次 `execve` 交出去的文件，内核没法直接执行 ——
它是一个 shebang 脚本。内核的处理方式和处理 `PT_INTERP` 是同一个思路：
*不跑这个文件，去找它指定的那个程序来跑*。只不过这次要找的不是动态链接器，
而是 `/usr/bin/python3`。

== 体检二：这一路上 exec 了什么

```sh
$ PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    strace -f -e trace=execve qutebrowser --version
```

去重之后，真正 exec 成功的程序只有四个：`qutebrowser`（脚本自身）、
`ldconfig`、`uname`、`file`。另外还有两个*不是 exec 出来的*：

```sh
execve("/usr/lib/qt6/QtWebEngineProcess", ["--type=zygote", "--no-zygote-sandbox", …])
execve("/usr/lib/qt6/QtWebEngineProcess", ["--type=zygote", …])
```

连 `qutebrowser --version` 这种「什么都不干」的调用，QtWebEngine 都会先起两个
zygote 模板进程。第 1 节讲的「fork 继承地址空间」在这里第一次露出它为什么值钱。

#note[
  ⚠️ 这个体检里有个*方法论陷阱*，第一次量的时候我就被骗了。

  不清 `PATH` 直接跑，trace 里会出现*几十条* `execve` —— 全都是在我的 mise 配置里
  逐个 install 目录试探 `uname` / `file` 的记录，跟 qutebrowser 毫无关系。

  也就是说：*测量环境本身也是变量。* 在把这类噪声清干净之前，
  任何关于「启动花了多少时间」的数字都不可信。

  还有一处我没查清：清掉 `PATH` 之后 `uname` / `file` / `ldconfig` 仍然出现，
  而 qutebrowser 自己不该调用它们。来源没查明，先记在这里。
]

== 体检三：Python 侧的账单

qutebrowser 的入口是 Python，所以先量它导入了什么。Python 自带一个开关：

```sh
$ python3 -X importtime -c "import qutebrowser.qutebrowser"
```

累计耗时最长的几项：

#table(
  columns: (auto, auto, 1fr),
  table.header([累计], [自身], [模块]),
  [90.4 ms], [0.9 ms], [`qutebrowser.qutebrowser`],
  [62.9 ms], [0.9 ms], [`qutebrowser.misc.earlyinit`],
  [38.9 ms], [2.2 ms], [`traceback`],
  [28.2 ms], [*10.4 ms*], [`_colorize`],
  [17.8 ms], [1.5 ms], [`dataclasses`],
  [17.5 ms], [0.4 ms], [`json`],
  [14.4 ms], [5.7 ms], [`inspect`],
  [13.6 ms], [1.2 ms], [`re`],
)

*一共 109 个模块，光是把它们导进来就要 90 毫秒。* 而这里最费时的一项
（`_colorize`，Python 3.14 给报错信息上色的模块）跟浏览器本身毫无关系 ——
它只是被 `traceback` 顺带拖进来的。

（完整脚本：`docs/labs/resident-browser/08-qutebrowser-checkup.sh`）


== 体检四：把那 1.2 秒切成几段

前面三步是分项看。这一节把它放回时间线上：给启动全程打上时间戳，
然后找几个*可以外部观测*的界标。

```sh
$ strace -f -tt -o trace.txt qutebrowser -R about:blank
```

三个界标（时刻取自一次真实运行）：

#table(
  columns: (auto, auto, 1fr),
  table.header([时刻], [相对], [事件]),
  [02:36:43.113], [0], [`execve("/usr/bin/qutebrowser")` —— 起点],
  [02:36:43.346], [*+233 ms*], [第一个 `libQt6*.so` 被打开 —— Python 阶段结束],
  [02:36:44.360], [*+1247 ms*], [第一次 connect 到 wayland —— 窗口要出现了],
)

于是这 1.25 秒大致分成两段：*前 233 毫秒是 Python*，*后 1014 毫秒是 Qt 和 QtWebEngine*。
跟体检三的 90 ms import 账单对得上 —— Python 那一侧的量级是对的。

=== 那 1014 毫秒具体在干什么

把这一段（+0.25s 到 +1.30s）里打开的路径按次数排出来：

```sh
  qutebrowser/qt/webkit.py  (+ .pyc)                   ← 导入 QtWebEngine 模块
  /usr/lib/qt6/plugins/platforms/libqwayland.so       ← Qt 装载平台后端
  /usr/lib/qt6/plugins/wayland-shell-integration/libxdg-shell.so
  /usr/lib/libOpenGL.so.0   libGLdispatch.so.0
  /usr/lib/libharfbuzz.so.0 libfreetype.so.6  libpng16.so.16  libgraphite2.so.3
  /usr/lib/libdbus-1.so.3   libxcb.so.1  libXau.so.6  libXdmcp.so.6
  /dev/shm/.org.chromium.Chromium.*                   ← Chromium 建共享内存段
```

同一段时间窗里的系统调用画像：

#table(
  columns: (auto, auto, 1fr),
  table.header([系统调用], [次数], [说明]),
  [`openat`], [932], [打开文件],
  [`read`], [1508], [读内容],
  [`newfstatat`], [1304], [问「这个文件在不在、多大」],
  [`mmap`], [1007], [映射进地址空间],
  [`fstat` / `lseek` / `close`], [875 / 630 / 916], [读完收尾],
  [`clock_gettime`], [2496], [各处计时],
)

*这是一段大量的小文件操作，不是在算东西。* 顺序上很清楚：
先导入 QtWebEngine 的 Python 模块，然后 Qt 装载平台后端和一堆本地库，
最后 Chromium 建立自己的共享内存。这三件事串起来就是那 1014 毫秒。

=== ⚠️ 这次量出来的，跟体检二对不上

体检二里，连 `qutebrowser --version` 都会 exec 出两个 `QtWebEngineProcess`。
但这一整份 trace 里，`QtWebEngineProcess` *一次都没出现*。

`strace -f` 会跟随所有 fork，所以这不是漏抓 —— 是这次运行*真的没有起那个进程*。
差别在哪，我还没查清楚（怀疑跟 `about:blank` 有关：没有真页面要渲染）。

记在这里而不是猜一个解释。

=== 还没拆出来的

+   adblock 规则解析 —— trace 里没找到对应的文件打开，还没定位到它在哪一段
+   profile 装载 —— 同样没有 `.sqlite` 出现在 trace 里（`-R` 跳过了会话恢复）
+   这 1.25 秒是「新 profile」还是「你的真实 profile」下的数字，也还没对比

== 体检到此为止：还有一大段没量

上面三步量到的，只是「解释器起来 + 模块导完」这一段。而 1.2 秒里还有：

+   Qt 的初始化 —— `PyQt6` 是在主函数里才导入的，不在上面那份账单里
+   QtWebEngine 的初始化 —— 体检二已经看到它连 `--version` 都会起 zygote
+   adblock 规则解析
+   profile 装载
+   窗口创建

这几段要接着量。

#punch[
  现在还不能下任何关于「能不能拆开」的结论 ——
  我们才刚看清这条链有几节。
]


= 3. 小结：现在知道什么，还不知道什么

*已经知道的：*

+   Linux 弄出一个新进程是两步：`fork` 复制一份，`execve` 把内容换掉
+   分成两步是为了留出中间那一步 —— shell 的重定向和管道都靠它
+   进程的内存是一堆区间拼起来的，叫地址空间，`/proc/self/maps` 可以直接看
+   可执行文件里有一张表，说清楚「哪段内容放到哪儿、什么权限」，内核照着搬
+   如果文件里写了「我需要解释器」，内核启动的其实是解释器，原程序交给它
+   解释器要做四件事：找库、搬进来、修正地址、调初始化
+   这一整套每次启动都要付，而且跟程序要做什么无关

*关于 qutebrowser：*

+   它不是一个二进制，是一个 970 字节的 Python 脚本
+   光把 Python 模块导进来就要 90 毫秒
+   从敲命令到窗口要出现一共 1.25 秒，切成两段：
    *前 233 毫秒是 Python，后 1014 毫秒是 Qt 和 QtWebEngine*
+   后面那 1014 毫秒做的事很具体：导入 QtWebEngine 模块 → Qt 装载平台后端 →
    一大堆本地库被映射进来 → Chromium 建立共享内存。
    全是*文件操作*，不是在算东西

*还不知道的：*

+   adblock 规则解析在哪一段 —— 没定位到
+   profile 装载在哪一段 —— 这次跑的是 `-R`，跳过了会话恢复
+   换成真实 profile（带会话恢复）会多出多少
+   那 1.25 秒里，究竟哪几段是*每次都完全一样*的

#punch[
  最后一条才是关键。在量出「哪几段是恒定的」之前，
  谈任何「能不能把这部分拆开、只付一次」都是空话。
]

这件事是下一章要做的。
