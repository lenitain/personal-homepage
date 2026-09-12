#set document(title: "Sample CV", author: "Placeholder")
#set page(paper: "a4", margin: 1.4cm)
#set text(size: 10pt)
#show link: set text(fill: rgb("#4b69c6"))

// 占位样例：跑通「typst → 编译期主题 → pdf.js」这条链路用，之后换成真文件。
// 故意用上 #grid 两栏、#table、彩色分隔线、链接和一张图 —— 这几种构造覆盖了
// spec 里踩过的坑（HTML 导出会丢 grid）和要做图像豁免反色的验证点。

#grid(
  columns: (1fr, 2.4fr),
  gutter: 1.2em,
  [
    #image("cv-portrait.png", width: 100%)
  ],
  [
    #text(size: 20pt, weight: "bold")[Placeholder Name]
    #v(0.2em)
    #text(size: 10pt, style: "italic")[Backend / Infrastructure]
    #v(0.6em)
    #link("https://example.com")[example.com]
    #v(0.8em)
    #rect(width: 100%, height: 3pt, fill: rgb("#E69875"))
  ]
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
  [homepage], [svelte + pdf.js preview layer],
)

= Notes

This page is a placeholder. Replace it with a real document; the layout is here to prove
that two-column grids, tables, links, and images all survive the compile step.
