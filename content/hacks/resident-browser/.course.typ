// 课件专用的语义块。被各章 #include，自己不以文件名出现在文件树里（点号开头）。
//
// 三种块对应课件里反复出现的三个动作：
//   think  先停一下，让读者猜    —— 讲下去之前留一个卡点
//   wrong  我当时的判断是错的    —— 记录被实验打脸的假设，这是课件里最值钱的部分
//   lab    实验                  —— 一段可以照着跑的东西
//
// 分工照本站的规矩：typst 只负责**语义**（交出一个带 class 的 div），
// **长相**由 DocumentView.svelte 里的样式表定。所以这里不写颜色、不写尺寸、不写间距。
//
// 为什么还要 `context if target()` 分流：本课程只走 HTML 导出，但这两个 helper 的
// PDF 分支留着，是为了将来真要用 PDF 时不至于连内容都组织不起来。摆放归摆放，
// 内容归内容。

#let course-box(kind, title, body) = context {
  if target() == "html" {
    html.elem(
      "div",
      [
        #html.elem("p", title, attrs: (class: "course-box-title"))
        #body
      ],
      attrs: (class: "course-box course-box-" + kind),
    )
  } else {
    block(inset: 8pt, stroke: 0.5pt)[*#title* #body]
  }
}

/// 章标题。
///
/// typst 的 HTML 导出把 `=` 映射成 `<h2>` —— 它给「文档标题」留出了 h1。而本课程
/// 每一章本身就是一份文档，标题理应是最外层的 h1（也才拿得到站点里那条绿色下划线
/// 的样式，跟 readme 的观感一致）。所以章标题不用 `=`，用这个。
#let title(body) = html.elem("h1", body)

/// 讲下去之前，先让读者自己下一个判断。
#let think(body) = course-box("think", "先停一下", body)

/// 记录一个被实验推翻的假设。课件的价值主要在这里，不在结论。
#let wrong(body) = course-box("wrong", "我当时的判断是错的", body)

/// 一段可以照着跑的实验。title 里写这一步想回答什么。
#let lab(title, body) = course-box("lab", title, body)
