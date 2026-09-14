// 这门课的目录数据 —— 目前唯一的一份。
//
// ## 为什么要有这个文件
//
// 这批课件里「刚才那件事发生在哪一章」被引用得太多了：入口的章节目录、
// 讲义封面的章节列表、每一章结尾的「下一章」、每一章正文里的回指。
// 这些引用以前是各写各的，于是同一件事在入口被记成「第一章」、在正文里
// 其实在第三章；同一批数字在入口和正文里差了 11 MiB。改一章要同步五个地方，
// 漂移是迟早的事。
//
// 现在章号只在这里出现一次。**章标题本身仍然是 `=` 一级标题，标题里的
// `序` / `1.` / `2.` 前缀是排版的一部分**，所以数据里不再重复写一遍编号，
// 只有章号（`n`）和引用时需要的那点信息。
//
// ## 编法：序 + 四章
//
// 第一种切法（`n: none`）是整门课的地基，只立机制、不下判断；后面四种切法
// 各回答一个具体问题，也就是「四章」。讲义沿用同一条线：`slides/1-...` 是
// 那次地基，`slides/2-...` 到 `slides/5-...` 是四章。

#let syllabus = (
  (
    n: none,
    file: "1-my-browser-is-slow.typ",
    slide: "slides/1-my-browser-is-slow.typ",
    title: "我的 qutebrowser 启动好慢，我该怎么办？",
    notes: (
      "先看清「跑一个程序」在 Linux 上是什么意思：fork 复制、execve 换内容",
      "地址空间是一列区间：映射不等于占用，同一份内容可以在几十个进程之间共用",
      "然后拿这套机制去体检普通的 qutebrowser：它是个 970 字节的 Python 脚本，光导入模块就要几十毫秒",
    ),
  ),
  (
    n: "1.",
    file: "2-when-to-daemonize.typ",
    slide: "slides/2-when-to-daemonize.typ",
    title: "什么样的程序值得常驻",
    notes: (
      "为什么值得常驻的不是「慢的程序」，是「开销可分离的程序」",
      "以及我把它记成 1 GB、实际只有 129 MiB 的那个数字",
    ),
  ),
  (
    n: "2.",
    file: "3-who-kills-it.typ",
    slide: "slides/3-who-kills-it.typ",
    title: "谁来释放资源",
    notes: (
      "生命周期的另一半",
      "为什么 PID namespace 是错的工具",
      "以及我怎么把自己的输入法搞丢了",
    ),
  ),
  (
    n: "3.",
    file: "4-what-deserves-ram.typ",
    slide: "slides/4-what-deserves-ram.typ",
    title: "什么该留在 RAM",
    notes: (
      "浏览器的历史、cookie、两份缓存，各自该待在哪",
      "overlayfs、shader cache、HTTP cache 各自该怎么处理",
    ),
  ),
  (
    n: "4.",
    file: "5-what-to-write-it-in.typ",
    slide: "slides/5-what-to-write-it-in.typ",
    title: "快路径用什么写",
    notes: (
      "同一个启动器，五种语言九个实现",
      "为什么动态链接的程序每次启动都要先跑一遍动态链接器（@@ld.so@@）",
      "量延迟、系统调用、地址空间、体积",
      "外加写它们时撞出来的一个缓冲区溢出",
    ),
  ),
)

// `notes` 里的字符串是在**代码**里写的，而代码里的反引号只是普通字符 ——
// 直接放进正文会原样显示成 `ld.so`。所以要显式按 markup 再解析一次。
// 用 `@@` 而不是 `\``：`\`` 在字符串字面量里是转义，写起来反而更绕。
#let _markup(text) = eval(text.replace("@@", "`"), mode: "markup")

/// 正文部分：第一章是地基，不是四章之一。
#let preface() = syllabus.at(0)

/// 四章本身。
#let chapters() = syllabus.slice(1)

/// 章号 → 一条元数据。`n` 写 "1." / "2." / … 这种形式。
#let chapter(n) = chapters().find(c => c.n == n)

/// 正文里提到某一章时用的书名号标题 —— **唯一正确的写法**。
///
/// 刻意把 `《》` 一起生成：手写引用时最容易漏的就是它，
/// 而漏了之后「《《标题》》」这种双书名号只有对着页面才看得出来。
#let chapterRef(n) = [《#chapter(n).title》]

/// 提到「序」的时候用它。
#let prefaceRef() = [《#preface().title》]

/// 入口页的章节目录。**这份课件的目录只在这里生成一次。**
///
/// 每个条目是一个 `block` 而不是靠换行排出来 —— typst 的 HTML 导出会把
/// 相邻的裸内容并进同一个 `<p>`，不切开就全挤成一段。
#let contents() = {
  let entry(head, item) = {
    block[#head *《#item.title》*]
    block(list(..item.notes.map(note => _markup(note))))
  }
  let head = if preface().n == none { [*序*] } else { [*#preface().n*] }
  entry(head, preface())
  for c in chapters() { entry([*#c.n*], c) }
}
