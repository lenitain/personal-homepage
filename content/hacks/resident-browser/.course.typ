// 课件的版式语汇。被各章 #import，自己不以文件名出现在文件树里（点号开头）。
//
// 章节目录**不在这里**，在 `.syllabus.typ` —— 同样靠点号开头从文件树里隐掉。
// 两个文件的分工：`syllabus` 说「这门课有哪几节、各叫什么」，这里说「内容长什么样」。
// 正文里引用别章要用 `syllabus` 的 `#chapterRef("2.")`，不要手打书名号标题。
//
// ## 为什么要有这个文件
//
// typst 的 HTML 导出会丢弃二维摆放原语（grid / place / columns / rect / line /
// stack / align / v），所以「排版」不能写在 typst 里。但**结构**可以：`html.elem`
// 能交出任意带 class 的 HTML，而站点的样式表可以把它摆成任何样子。
//
// 分工因此是：**typst 说「这是什么」，CSS 说「它长什么样、放在哪」。**
// 这个文件负责前一半，DocumentView.svelte 负责后一半。
//
// ## 为什么要这么多形状
//
// 讲义如果只有「标题 + 条目」两种形状，读起来就是一份大纲 —— 层级再多也还是大纲，
// 因为所有东西的重量都一样。可读的版式需要**不同重量的容器**：
// 正文是平的，提问要跳出来，实验记录要一眼看出是记录，结论要落地。
//
// 试过一版全是彩色提示框的，不行：框一多，注意力就被框吸走，读者开始收集框而不是
// 读内容。所以这里按**重量**分档 —— 提问(轻) / 实验与纠正(中) / 结论(落地)，
// 旁注比正文还轻。

/// 章标题。
///
/// typst 的 HTML 导出把 `=` 映射成 `<h2>` —— 它给「文档标题」留出了 h1。
/// 而本课程每一章本身就是一份文档，标题理应是最外层那个（也才拿得到站点里
/// 绿色下划线那条样式，跟 readme 的观感一致）。所以章标题不用 `=`，用这个。
#let title(body) = html.elem("h1", body)

/// 一张幻灯片。演示模式下它就是「一屏」，阅读模式下只是一个普通分节。
///
/// 幻灯片版专用 —— 文档版不用它，两者的切法不同（见 slides/ 目录）。
///
/// HTML 目标下交出 `<section class="c-slide">`，翻页交给站点的 CSS（scroll-snap）
/// 和键盘处理；PDF 目标下退化成真正的分页。这样同一份幻灯片源既能当网页讲，
/// 也能导出成 PDF 带走。
#let slide(body) = context {
  if target() == "html" {
    html.elem("section", body, attrs: (class: "c-slide"))
  } else {
    pagebreak(weak: true)
    body
  }
}

/// 内部：交出一个带标签的容器。label 为 none 时不渲染标签行。
#let _box(kind, label, body) = context {
  if target() == "html" {
    if label == none {
      html.elem("div", body, attrs: (class: "c-box c-" + kind))
    } else {
      html.elem(
        "div",
        [
          #html.elem("p", label, attrs: (class: "c-label"))
          #body
        ],
        attrs: (class: "c-box c-" + kind),
      )
    }
  } else {
    // PDF 目标下退化成可读的块。本课程只走 HTML，这一支留着是为了将来
    // 真要出 PDF 时不至于连内容都组织不起来。
    if label == none {
      block(inset: 8pt, stroke: 0.5pt, body)
    } else {
      block(inset: 8pt, stroke: 0.5pt)[*#label* #body]
    }
  }
}

/// 留给读者的提问。讲到一半停下来，让读者自己先下一个判断。
///
/// 这是整套版式里最该被看见的一块 —— 读者一路翻过去就等于没读，
/// 所以它比正文重，但比结论轻。
#let ask(body) = _box("ask", "先停一下", body)

/// 一段实验记录。title 写这一步想回答什么，body 里放**原始输出**，不要摘要。
#let lab(title, body) = _box("lab", title, body)

/// 一个被实验结果推翻的判断。
#let oops(label: "我猜错了", body) = _box("oops", label, body)

/// 旁注：比正文还轻，可以跳过不读。
#let note(body) = _box("note", none, body)

/// 结论。一段推到底之后落地的那一句。
#let punch(body) = _box("punch", none, body)

/// 两栏对照。左右各放一段内容，窄屏自动摊成一栏。
///
/// 用途是把「预期 / 实际」「修复前 / 修复后」这类对照并排放 ——
/// 并排比上下叠着更容易看出差别，这是横向空间该干的活。
#let cols(left, right) = context {
  if target() == "html" {
    html.elem(
      "div",
      [
        #html.elem("div", left, attrs: (class: "c-col"))
        #html.elem("div", right, attrs: (class: "c-col"))
      ],
      attrs: (class: "c-cols"),
    )
  } else {
    grid(columns: (1fr, 1fr), gutter: 1em, left, right)
  }
}
