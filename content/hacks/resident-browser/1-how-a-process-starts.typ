#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "一个进程是怎么起来的")

#title[一个进程是怎么起来的]

这一章讲一件事：你在终端敲下一个命令、按下回车之后，到你的代码第一行开始执行之前，
系统做了哪些事。

把它放第一章，是因为后面每一章都在跟它的开销打交道。「启动要一秒」「常驻能省下一份
前言」「静态链接比动态快」—— 这些话里的每一个名词，指的都是这一章里的某几步。
不先把机制看清楚，那些数字就只是一堆数。

= 1. 内核做的事：把段落搬进地址空间

`execve` 是这一切的起点。它做的是*替换*，不是新建 —— 当前进程的内存全部丢掉，
换成一个新程序的。

内核拿到一个可执行文件之后，第一件事是认格式。ELF 文件开头是一张*段表*
（program header），每一项描述「要往地址空间里放一段东西」：

#table(
  columns: (auto, 1fr),
  table.header([段类型], [含义]),
  [`PT_LOAD`], [要映射进地址空间的段，每段自带权限：只读 / 可执行 / 可写],
  [`PT_INTERP`], [这个文件自己跑不起来，需要先请一个解释器],
  [`PT_DYNAMIC`], [给链接器看的一张表：依赖哪些库、重定位表在哪],
)

内核只做一件事：*把每个 `PT_LOAD` 描述的区间 mmap 到新建的地址空间里*，
地址用段表里写的虚拟地址，权限用段表里写的权限。做完这些，地址空间就成形了。

这件事可以直接看见 —— 下面左边是段表，右边是同一个程序的地址空间，一一对应：

#lab("演示 04：段表与地址空间")[
  ```sh
  $ readelf -lW hello-static | grep -E 'Type|LOAD'
    Type   Offset   VirtAddr           FileSiz  MemSiz   Flg
    LOAD   0x000000 0x0000000000400000 0x000500 0x000500 R
    LOAD   0x001000 0x0000000000401000 0x08a7e5 0x08a7e5 R E
    LOAD   0x08c000 0x000000000048c000 0x0352d0 0x0352d0 R
    LOAD   0x0c2148 0x00000000004c2148 0x0058e0 0x00b1c0 RW
  ```

  ```sh
  $ cat /proc/self/maps
  00400000-00401000 r--p 00000000  …/maps-static
  00401000-0048c000 r-xp 00001000  …/maps-static
  0048c000-004c2000 r--p 0008c000  …/maps-static
  004c2000-004c6000 r--p 000c2000  …/maps-static
  004c6000-004c8000 rw-p 000c6000  …/maps-static
  004c8000-004ce000 rw-p 00000000  [heap]
  ```

  段表的四行对应地址空间的前五行：起始地址一样、长度一样、权限一样
  （`R` → `r--p`，`R E` → `r-xp`，`RW` → `rw-p`）。

  最后那段 `RW` 的 `MemSiz` 比 `FileSiz` 大：多出来的部分就是 `.bss` ——
  文件里不占空间，但进程里要占，内核给它一段匿名零页。

  （完整脚本：`docs/labs/resident-browser/04-elf-loading.sh`）
]

「地址空间里的那些 VMA」不是抽象概念，就是这些东西。后面几章会反复用到它：
静态二进制的 VMA 少，是因为它的段表本身就短。

= 2. 有些文件自己跑不起来

段表里只要有 `PT_INTERP`，事情就变了一层。这时内核做完 mmap 之后跳转的*不是*这个程序，
而是一个叫解释器（interpreter）的另一个可执行文件；原程序只是作为参数被交出去。

#lab("演示 04：有没有 PT_INTERP，差别在哪")[
  ```sh
  $ readelf -lW hello-static | grep -A1 INTERP
  （没有这个段）

  $ readelf -lW hello-dyn | grep -A1 INTERP
    INTERP  0x0003ac  …  0x00001c
        [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  ```

  两个程序都只打印一行 `hello`，但启动过程完全不同。用 `strace` 看：

  ```sh
  # 动态版：execve 之后
  1. execve("./hello-dyn", …) = 0
  3. openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
  5. mmap(NULL, 167295, PROT_READ, MAP_PRIVATE, 3, 0) = 0x7f66ed2ce000
  11. openat(AT_FDCWD, "/usr/lib/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
  14. mmap(NULL, 2464592, PROT_READ,  MAP_PRIVATE|MAP_DENYWRITE, 3, 0) = 0x7f66ed000000
  15. mmap(0x…, 1769472, PROT_READ|PROT_EXEC, MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 3, 0x24000)
  16. mmap(0x…,  491520, PROT_READ,         MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 3, 0x1d4000)
  17. mmap(0x…,   24576, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_DENYWRITE, 3, 0x24c000)
  18. mmap(0x…,   31568, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_FIXED|MAP_ANONYMOUS, -1, 0)
  系统调用总数: 36

  # 静态版：execve 之后
  1. execve("./hello-static", …) = 0
  2. brk(NULL) = 0x360f9000
  4. arch_prctl(ARCH_SET_FS, 0x360f9400) = 0
  5. set_tid_address(0x360f9a28) = 126672
  系统调用总数: 19
  ```

  动态版那四行 `mmap` 值得盯着看：*同一个 fd、`MAP_FIXED`、四段*
  —— 那是 libc 的四个 `PT_LOAD` 段被逐段映射进来，和第 1 节里内核做的事一模一样，
  只是这次是链接器在替 libc 做。

  静态版没有这一整套：`execve` 之后只剩设置线程局部存储、注册 tid 这些收尾。
]

= 3. 链接器接着做完的四件事

`/lib64/ld-linux-x86-64.so.2` 是动态链接器。它拿到的第一个任务，是把上面那个
「自己跑不起来」的程序真正跑起来。为此它要做四件事：

+   *找库* —— 读 `/etc/ld.so.cache` 和各库的 `DT_NEEDED`，递归找到全部依赖
+   *映射* —— 把每个 `.so` 的 `PT_LOAD` 段 mmap 进来
+   *重定位* —— 修正地址
+   *调 init* —— 按依赖顺序调用每个目标文件的初始化函数

第三件最反直觉，值得说清楚：*为什么地址要「修正」？*

因为 ASLR。程序编译时假设自己从某个固定地址开始，代码和数据里凡是需要写绝对地址的地方，
都是按那个假设填的。但每次运行，加载器会把程序放在一个随机基址上。于是所有写死的地址
都得重算一遍 —— 这就是重定位。

#lab("演示 05：把链接器的工作打出来看")[
  glibc 自带三个调试开关，把它每一步都打出来：

  ```sh
  # 找库：注意它在按 glibc-hwcaps 的层级逐级回退
  $ LD_DEBUG=libs ./ctor-demo
    find library=libctor.so [0]; searching
      trying file=…/glibc-hwcaps/x86-64-v3/libctor.so
      trying file=…/glibc-hwcaps/x86-64-v2/libctor.so
      trying file=…/libctor.so
    find library=libc.so.6 [0]; searching
      trying file=…/libc.so.6
      trying file=/usr/lib/libc.so.6

  # 调 init：顺序就是依赖顺序，主程序排最后
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

  `calling init` 那四行是本节的要点：*你的 `main` 不是第一个跑的东西*。
  ld.so 自己在最前，然后是 libc，然后是你依赖的库，最后才轮到主程序。
  每一层都依赖下一层已经就绪 —— 顺序不能颠倒。

  （完整脚本：`docs/labs/resident-browser/05-dynamic-loader.sh`）
]

== 3.1 惰性绑定：一个正在消失的机制

讲动态链接的教材都会花篇幅讲 *PLT 惰性绑定*：调用外部函数时先跳一小段桩代码，
桩代码去查表，第一次查不到就请链接器解析，然后把结果填回表里 —— 所以
「第一次调用某个函数」比后面几次贵。

这个机制今天基本看不到了，因为发行版默认加 `-z now`：链接器在启动时就把整张表解析完。
原因是延迟可预测，而且完整的 RELRO 能让一部分内存变成只读，挡住一类攻击。

但「懒」和「不懒」的差别还是可以造出来看：

#lab("演示 05：造一个永不调用的函数")[
  库里两个函数，主程序只调用其中一个 —— 另一个的分支永远不成立：

  ```c
  int main(int argc, char **argv) {
      if (argc > 99) never_called();   /* argc 不可能到 99 */
      called_sometimes();
  }
  ```

  ```sh
  【懒（默认）】DT_FLAGS_1 里有 NOW 吗：0
      called_sometimes 绑定了几次：1
      never_called     绑定了几次：0     ← 一次都没解析

  【全绑（-z now）】DT_FLAGS_1 里有 NOW 吗：2
      called_sometimes 绑定了几次：1
      never_called     绑定了几次：1     ← 启动时就解析了
  ```

  所以 `-z now` 不是「删掉 PLT」，是「不再拖到第一次调用才解析」。
  代价是启动时多做一点工作。
]

= 4. 这套流程的账单

把上面几步放回我们关心的场景：一个「什么都不干」的进程，启动要花多少钱？

#cols[
  *只 `exit_group` 的静态二进制*
  ```sh
  224 µs   ← 这是 fork + execve + wait
            本身的地板
  ```
][
  *`/bin/true`（动态 glibc）*
  ```sh
  505 µs   ← 多了 281 µs
  ```
]

那 281 µs 就是第 2、3 节里那一整套。`LD_DEBUG=statistics` 说链接器自己只花了几万
cycle（几十微秒），剩下的是*打开并映射那些库*，以及随之而来的缺页 ——
映射只是登记，真正把页面从磁盘读进来是访问到的时候才发生的。

#note[
  这也是为什么「静态链接更快」的收益不稳定：它省掉的是链接器的计算，但一个静态
  glibc 二进制是 826 KB，本身要多映射不少页。省下的和付出的会互相抵消一部分 ——
  详细数字在第 5 章。
]

= 5. 什么样的开销可以提前付

前四节讲的这套流程，有一个很重要的性质：*它跟你的程序要做什么毫无关系。*
同样的库、同样的重定位、同样的 init 顺序，不管你接下来是要打开一个网页还是五十个。

既然每次完全一样，那能不能只付一次？

可以，但前提是*不要 exec 一个新进程*。`fork` 出来的子进程拿到的是一份已经建好的
地址空间的副本（内核用写时复制，并不真的拷内存）：库的映射、重定位的结果、
构造函数跑完的状态，全都在里面。第 3 节那四步，一次都不用再做。

两条路的差别可以直接量出来：

#lab("演示 06：fork 继承 vs exec 重来")[
  造一个「很贵」的库（构造函数里初始化 8 MB 数据段）。两条路各派生 40 次：

  ```sh
  A）zygote：父进程加载一次，之后全靠 fork
      构造函数跑了几遍: 1
      总耗时:           19 ms

  B）exec：每次 exec 一个全新进程
      构造函数跑了几遍: 40
      总耗时:           188 ms
  ```

  *同一个库，同一个工作量，差 9.9 倍。* 差的全部来自「要不要重新走一遍
  找库 / 映射 / 重定位 / init」。

  （完整脚本：`docs/labs/resident-browser/06-zygote-prefork.sh`）
]

== 5.1 真实系统里的样子：zygote

这不是我编出来的技巧，Chromium 和 QtWebEngine 就是这么干的。在跑着 qutebrowser
的机器上直接读进程表：

```sh
$ （列出所有 QtWebEngineProcess，pid / 父进程 / 类型）
  1633    1357    zygote
  1634    1357    zygote
  1636    1634    zygote      ← 父进程是另一个 zygote
  1689    1636    renderer    ← 父进程是 zygote
  6151    1636    renderer
  112935  1636    renderer
  1836    1357    utility
```

浏览器本体（1357）启动两个 zygote；其中一个再 fork 出「渲染器模板」；
*每个渲染器都是从那个模板 fork 出来的* —— 所以打开一个新标签页不需要重新加载
VMA 那一千多个映射。

证据不只是父子关系，还有地址空间本身：

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

两者映射的共享库列表*完全一致* —— renderer 一个共享库都没有自己加载。
它多出来的那部分 RSS 是跑起来之后的堆和 JIT 代码，不是加载新库的开销。

== 5.2 判断标准

#punch[
  一个开销能不能提前付，看的是有没有一条进程边界，
  让贵的那部分跨多次使用共享。
]

QtWebEngine 有这条边界：引擎的状态跟「你打开哪个网页」无关，所以它可以活在一个
单独的进程里，每个新标签页从它 fork 一下。zygote 就是「共享的那一份」的载体。

反过来说，如果每次要用的东西都必须跟这次请求绑定、没法共享，那就没有可提前付的部分。
这正是下一章那个判据 —— 只是那里讲的是「值不值得」，这里讲的是「能不能」。

= 6. 小结

+   `execve` 换掉整个地址空间；内核按 `PT_LOAD` 把段落 mmap 进来 —— VMA 就是这么来的
+   有 `PT_INTERP` 的文件自己跑不起来，内核启动的其实是 `ld.so`
+   链接器接着做四件事：找库、映射、重定位、按依赖顺序调 init
+   这四件事跟程序要做什么无关，每次启动都要付
+   如果贵的那部分能跨多次使用共享，就用 `fork` 继承，别 `exec` 重来

下一章：这条结论落到一个具体问题上 —— 什么样的程序值得为它常驻。
