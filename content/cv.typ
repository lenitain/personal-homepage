// 占位样例：跑通「typst → 结构 → HTML / PDF」这条链路用，之后换成真文件。
//
// 这份文档同时服务两个导出目标（`typst compile --format html` 与 `--format pdf`）。
// 两者的能力边界是**结构 vs 视觉**：HTML 导出保留语义（标题、列表、表格、图片、链接、
// 行内标记），丢弃二维摆放（grid / place / align / stack / rect / line / columns / v）；
// PDF 导出反过来，什么都能摆，但产物是死版面、且没有语义。
//
// 所以分工是：**内容写一份，摆放按目标分流**。下面两个 `context if target()` 就是分流点。
// 注意不能把内容数组直接交给 `html.elem` —— 它只收一个 content，数组要先 `join()`，
// 否则整个数组会被当成代码渲染成 `<code>`。

#set document(title: "Sample CV", author: "Placeholder")

// 页面尺寸是印刷概念。HTML 下这条会被忽略并报 warning，按目标分流让诊断输出干净。
#context if target() != "html" {
  set page(paper: "a4", margin: 1.4cm)
  set text(size: 10pt)
}

/// 两栏容器：HTML 交出一个带 class 的 div（怎么摆归站点样式表），PDF 交出真正的 grid。
#let site-columns(..body) = context {
  if target() == "html" {
    html.elem("div", body.pos().join(), attrs: (class: "cv-columns"))
  } else {
    grid(columns: (1fr, 2.4fr), gutter: 1.2em, ..body.pos())
  }
}

// 名字与头衔：HTML 里交出一级标题和一个段落（语义正确、样式归样式表）；
// PDF 里用字号和斜体表达，因为那边只有视觉。
#let site-name(name) = context {
  if target() == "html" {
    html.elem("h1", attrs: (class: "cv-name"))[#name]
  } else {
    text(size: 20pt, weight: "bold")[#name]
  }
}

#let site-subtitle(text-body) = context {
  if target() == "html" {
    html.elem("p", attrs: (class: "cv-subtitle"))[#text-body]
  } else {
    text(size: 10pt, style: "italic")[#text-body]
  }
}

#site-columns(
  // 左栏：照片。`#image` 在两个目标下都是语义图片。
  [#image("cv-portrait.png", width: 100%)],

  // 右栏：名字、头衔、链接、分隔线。段落之间的间距（原来那些 `#v`）也归样式表 ——
  // `#v` 是摆放，HTML 导出会丢弃它并报 warning。
  [
    #site-name[Placeholder Name]
    #site-subtitle[Backend / Infrastructure]
    #link("https://example.com")[example.com]
    // 分隔线用官方的 `divider`（0.15 新增）：HTML 目标下它就是 `<hr>`，
    // PDF 目标下是可被 show rule 改样式的分隔线。比原来的 `#rect` 好 ——
    // `#rect` 是画图元语，HTML 里没有对应物，只能丢。
    #divider()
  ],
)

= Experience

- *Yazi* — terminal file manager contributor
- *mise* — toolchain tinkering
- *typst* — typesetting experiments

= Projects

#table(
  columns: (1fr, 2fr),
  inset: 6pt,
  stroke: 0.5pt,
  [dotfiles], [text-only environment, no image packing],
  [homepage], [svelte + typst preview layer],
)

= Notes

This page is a placeholder. Replace it with a real document; the layout is here to prove
that two-column structure, tables, links, and images all survive both export targets.
