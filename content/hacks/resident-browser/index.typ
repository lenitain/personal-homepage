#import "../../.course.typ": title, ask, lab, oops, note, punch, cols
#import ".syllabus.typ": preface, chapters, chapterRef, prefaceRef, contents

#set document(title: "一个已经开着的浏览器")

#title[一个已经开着的浏览器]

qutebrowser 启动要 1.2 到 1.9 秒。窗口先出来，然后页面才出来。它不是个慢程序，
但这一秒多足够让你每次都注意到 —— 一天二十次。

这门课记录的是把它压到 *232 毫秒*的全过程，以及代价到底是什么。
里面没有一处是在让浏览器本身变快。

= 1. 这门课在教什么

表面上是关于一个浏览器的笔记 —— *序*加*四章*。实际上它反复在做同一件事：

#punch[
  拿到一个「顺手」的机制，然后问它原本是为哪个问题造的。
]

这件事之所以值得单独教，是因为*错的工具如果当场就报错，你会立刻换一个；
它要是能用，你就会一直在它上面打补丁*。这门课里最贵的一个坑，
就是一个「能用」的错工具 —— 我拿 PID namespace 去做进程回收，
它确实能回收，代价是我的输入法没了，而且我花了一整章才想明白为什么。

== 另一个反复出现的主题

三次，我都是拿脑子里的模型代替了观测：

-   常驻开销我记成「700 MB 到 1 GB」，量出来是一百多 MiB（#chapterRef("1.")）
-   我以为一段「一直能用」的代码就是对的，它其实一直在缓冲区外面写 ——
    露出来，只是因为同一个行为被写了两遍（#chapterRef("4.")）
-   一个实验「跑通了」但其实完全无效，因为 `$$` 被 systemd 展开成了字面 `$`（#chapterRef("2.")）

这三个不是独立的事故，是同一种失误的三个变体。
所以每一章里凡是能跑的东西都跑了，输出直接贴在里面。

= 2. 课程信息

-   *形态*：#prefaceRef() 是地基，不计入章数；正文#chapters().len() 章。
    中文正文 + 英文术语，用 #link("https://typst.app/")[typst] 写
-   *前置知识*：会读 C，知道进程是什么，用过命令行
    -   不需要写过内核模块，不需要读过 Linux 源码
-   *实验*：全部可复现，脚本在 `docs/labs/resident-browser/`
    -   每一章里贴的输出，都是这些脚本真跑出来的，不是手抄的
-   *环境*：Linux + systemd + Wayland
    -   部分实验需要非特权 user namespace 可用

= 3. 章节目录

#contents()

= 4. 怎么读

每一章的节奏是固定的三段：

+   *机制* —— 它为什么是这个样子
+   *演示* —— 当场把它跑出来看，输出直接贴在里面
+   *数字* —— 所以那个数字是什么意思

凡是能跑的都跑了。*每一个结论，都对应一个你可以自己重跑一遍的脚本。*

所以你会看到很多「先停一下」，那是留给你自己先回答的。

#ask[
  请真的停一下。直接看答案的话，这门课就只剩下结论了 —— 而结论是最没有价值的部分。

  因为数字和实现会被更好的工具、更强的模型重新做一遍；
  「为什么问这个问题、当时期待看到什么、被什么打脸、于是怎么改假设」不会。
]

= 5. 实验器材

二十七支脚本加一套九个实现的启动器，全在 `docs/labs/resident-browser/`。
每一章贴的输出都出自它们，脚本和章节的对照表在那一层的 `README.md`。

两条使用须知，都是踩出来的：

-   *测量脚本要绑核*（`taskset`）—— 不绑核，同一份代码的读数能差一半
-   *`overflow-check.sh` 必须在 mount namespace 里跑*，它自己会做 ——
    那个 bug 的失败模式包含「`execve` 成功」这一种，直接跑会真的拉起你的浏览器

= 6. 结果

#table(
  columns: (1fr, auto, auto),
  table.header([], [之前], [之后]),
  [打开一个页面], [1227 ms], [232 ms],
  [常驻成本], [0], [一百多 MiB],
  [进程树], [1], [2–5],
  [启动器开销], [—], [377.6 µs],
  [生命周期保证], [无], [pid 1 级],
)

其中两行有口径，别跟别处的数字混着看：

-   *常驻成本*是零窗口、空 profile 的 `MemoryCurrent`（#chapterRef("1.")，演示 12）。
    它跟着机器状态动 —— 这份课件写到这一版时量到 129 MiB，重跑是 136 MiB，
    所以这里只写量级
-   *启动器开销*是 `latency.sh` 绑核三轮 × 500 次的*最小值*（#chapterRef("4.")）；
    同一支脚本在 `measure.sh` 口径下是 p50 543 µs —— 两处数不一样是因为量法不一样

#punch[
  把开销恒定的那部分保温，
  把它的生命周期交给一个本来就管生命周期的东西，
  把能重做的东西赶回磁盘。
]

= 7. 代码

全都在我的 dotfiles 里：

-   #link("https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/qutebrowser/config.py")[qutebrowser 配置] —— 缓存相关的决定都写在注释里
-   #link("https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-server")[`qb-server`] —— 打了补丁、零窗口也不退出的 qutebrowser
-   #link("https://github.com/lenitain/dotfiles/blob/main/dotfiles/.local/bin/scripts/qb-open.c")[`qb-open`] —— C 写的启动器，191 行
-   #link("https://github.com/lenitain/dotfiles/blob/main/dotfiles/.config/systemd/user/qb-server.service")[`qb-server.service`] —— 交出去的生命周期

= 8. 从哪开始

如果只读一章，读*#chapterRef("2.")*。那一章的实验最完整，
而且它教的是一次*调试*，不是一个结论。

否则就按左边文件树里的顺序往下走。
