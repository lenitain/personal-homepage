#import "../.course.typ": note, punch, slide, title

#set document(title: "什么该留在 RAM（讲义）")

// 切法跟文档版不同：一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 跑出来的结果不进讲义 —— 讲课的时候当场跑，讲义上只留脚本路径。
// 唯一留在讲义上的是*概念性*的表：它不是量出来的，是在解释一种结构。

#slide[
  #title[什么该留在 RAM]

  释放资源的人定了。这一章是开销的问题。
]

#slide[
  = 把浏览器的数据不应该全部放进 RAM

  内核本来就会把读过的文件页留在内存里 —— 放在磁盘上，不等于每次都读盘。
  而 tmpfs 里的页没有持久化存储机制，tmpfs 在文件系统被卸载时自然丢失。
]

#slide[
  = 三样数据，三个去处

  #table(
    columns: (1fr, auto, 1fr),
    table.header([东西], [该在哪], [为什么]),
    [这次写下的历史、cookie], [RAM 和磁盘], [丢了就没了、马上还要用],
    [shader / HTTP 缓存], [磁盘], [随时能重做、又大又冷],
    [DOM、JS 堆、媒体], [关页即释放], [跟着标签页一起消失],
  )

  开销集中在第二行，那两份缓存是大头。

  #note[现场跑：`./docs/labs/resident-browser/12-resident-memory.sh`]
]

#slide[
  = overlayfs：RAM 里放的是增量

  - 底下：磁盘上的只读层
  - 上面：内存文件系统（tmpfs）上的可写层
  - 从不写的文件 → 仍然从磁盘读
  - 第一次写 → *copy-up* 到 tmpfs

  每小时 resync 把增量写回磁盘备份。

  #punch[把一个 profile 整份拷进 tmpfs，你会为「只被读过」的文件付内存。]
]

#slide[
  = shader cache 每次启动都被重写

  QtWebEngine 会在 profile 边上写一份编译好的 shader 缓存，
  而且每次启动重写一遍。

  在 overlay 之下，「每次重写」等于「每次 copy-up 进 RAM」——
  一块又大又脏、且无法回收的内存。

  ```sh
  c.qt.args = ["disable-gpu-shader-disk-cache"]
  ```
]

#slide[
  = 这笔交易的前提是浏览器已经常驻

  #punch[它只有在浏览器常驻之后才是免费的。]

  冷启动（每次都从零起一个浏览器）的话，你每次都要重新编译 shader，
  付的是实打实的时间。常驻之后 shader 一次会话只编译一次，磁盘缓存就没东西可省了。
]

#slide[
  = HTTP 缓存很大，该不该在 RAM 里

  在磁盘上它花的是内核的缓存页，内存紧张时可以丢掉；
  放在 tmpfs 里，它花的是*谁也回收不了的内存*。

  所以：设个上限，放在磁盘上，让内核决定这些页值不值得留着。
]

#slide[
  = 关闭窗口后留下的那个渲染进程不是泄漏

  它*没有*攥着任何已关闭的页面 ——
  它是等着下一个页面的共享基础设施，而这正是常驻设计的目的。
]

#slide[
  #punch[
    将全部数据加载至 RAM 会产生不必要的开销，
    应结合存储层级与资源特性来制定存储方案。
  ]
]
