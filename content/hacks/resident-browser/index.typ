#import ".course.typ": title, ask, lab, oops, note, punch, cols

#set document(title: "一个已经开着的浏览器")

#title[一个已经开着的浏览器]

qutebrowser 启动要大约 1.2 秒。窗口先出来，然后页面才出来。它不是个慢程序，
但 1.2 秒足够让你每次都注意到 —— 一天二十次。

这门课记录的是把它压到 *232 毫秒*的全过程，以及代价到底是什么。
里面没有一处是在让浏览器本身变快。

= 1. 这门课在教什么

表面上是四章关于一个浏览器的笔记。实际上它反复在做同一件事：

#punch[
  拿到一个「顺手」的机制，然后问它原本是为哪个问题造的。
]

这件事之所以值得单独教，是因为*错的工具如果当场就报错，你会立刻换一个；
它要是能用，你就会一直在它上面打补丁*。这门课里最贵的一个坑，
就是一个「能用」的错工具 —— 我拿 PID namespace 去做进程回收，
它确实能回收，代价是我的输入法没了，而且我花了一整章才想明白为什么。

== 另一个反复出现的主题

-   我凭印象写下的数字，量过之后*错了七倍*（第一章）
-   我以为「多语言实现」的价值在对比表，实际价值在它抓出来的一个内存越界写（第四章）
-   一个实验「跑通了」但其实完全无效，因为 `$$` 被 systemd 展开成了字面 `$`（第二章）

这三个不是独立的事故，是同一种失误的三个变体：*用自己脑子里的模型代替观测*。
所以每一章里凡是能跑的东西都跑了，输出直接贴在里面。

= 2. 课程信息

-   *形态*：四章，中文正文 + 英文术语，用 [typst](https://typst.app/) 写
-   *前置知识*：会读 C，知道进程是什么，用过命令行
    -   不需要写过内核模块，不需要读过 Linux 源码
-   *实验*：全部可复现，脚本在 `docs/labs/resident-browser/`
    -   每一章里贴的输出，都是这些脚本真跑出来的，不是手抄的
-   *环境*：Linux + systemd + Wayland
    -   部分实验需要非特权 user namespace 可用

= 3. 章节目录

+   *我的 qutebrowser 启动好慢，我该怎么办？*
    -   先看清「跑一个程序」在 Linux 上是什么意思：fork 复制、execve 换内容
    -   内核按段表把 `PT_LOAD` 映射进地址空间 —— VMA 就是这么来的
    -   有 `PT_INTERP` 的文件自己跑不起来，内核启动的其实是 `ld.so`
    -   然后拿这套机制去体检普通的 qutebrowser：它是个 970 字节的 Python 脚本，
      光导入模块就要 90 ms
+   *什么样的程序值得常驻*
    -   为什么值得常驻的不是「慢的程序」，是「开销可分离的程序」
    -   以及我把它记成 1 GB、实际只有 140 MiB 的那个数字
+   *谁来收尸*
    -   生命周期的另一半
    -   为什么 PID namespace 是错的工具
    -   以及我怎么把自己的输入法搞丢了
+   *什么该留在 RAM*
    -   浏览器 profile 里大部分字节是死的
    -   overlayfs、shader cache、HTTP cache 各自该在哪
+   *快路径用什么写*
    -   同一个启动器，五种语言九个实现
    -   量延迟、系统调用、地址空间、体积
    -   外加写它们时撞出来的一个缓冲区溢出

= 4. 怎么读

每一章的节奏是固定的三段：

+   *机制* —— 它为什么是这个样子
+   *演示* —— 当场把它跑出来看，输出直接贴在里面
+   *数字* —— 所以那个数字是什么意思

凡是能跑的都跑了。*这一章里的每个结论，都对应一个你可以自己重跑一遍的脚本。*

所以你会看到很多「先停一下」，那是留给你自己先回答的。

#ask[
  请真的停一下。直接看答案的话，这门课就只剩下结论了 —— 而结论是最不值钱的部分。

  因为数字和实现会被更好的工具、更强的模型重新做一遍；
  「为什么问这个问题、当时期待看到什么、被什么打脸、于是怎么改假设」不会。
]

= 5. 实验器材

/ `10-namespace-failure-modes.sh`: PID namespace 的三个失败面
/ `11-cgroup-vs-mainpid.sh`: scope 和 service 差在哪
/ `12-resident-memory.sh`: 常驻到底占多少内存
/ `overflow-check.sh`: C 版缓冲区溢出的边界
/ `launchers/`: 九个实现，五种语言
/ `build-all.sh`: 全部构建 + 测量

两条使用须知，都是踩出来的：

-   *测量脚本要绑核*（`taskset`）—— 不绑核，同一份代码的读数能差一半
-   *`overflow-check.sh` 必须在 mount namespace 里跑*，它自己会做 ——
    那个 bug 的失败模式包含「`execve` 成功」这一种，直接跑会真的拉起你的浏览器

= 6. 结果

#table(
  columns: (1fr, auto, auto),
  table.header([], [之前], [之后]),
  [打开一个页面], [1227 ms], [232 ms],
  [常驻成本], [0], [140 MiB],
  [进程树], [1], [2–5],
  [启动器开销], [—], [317 µs],
  [生命周期保证], [无], [pid 1 级],
)

#punch[
  把开销恒定的那部分保温，
  把它的生命周期交给一个本来就管生命周期的东西，
  把一切死的字节赶回磁盘。
]

= 7. 代码

全都在我的 dotfiles 里：

-   [qutebrowser 配置](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/qutebrowser/config.py) —— 缓存相关的决定都写在注释里
-   [`qb-server`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-server) —— 打了补丁、零窗口也不退出的 qutebrowser
-   [`qb-open`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-open.c) —— C 写的启动器，191 行
-   [`qb-server.service`](https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/systemd/user/qb-server.service) —— 交出去的生命周期

= 8. 从哪开始

如果只读一章，读*《谁来收尸》*。那一章的实验最完整，
而且它教的是一次*调试*，不是一个结论。

否则就按左边文件树里的顺序往下走。
