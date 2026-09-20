#import "../../../.course.typ": note, punch, slide, title
#import "../.syllabus.typ": chapterRef

#set document(title: "什么该留在 RAM（讲义）")

// 切法跟文档版不同：一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 跑出来的结果不进讲义 —— 讲课的时候当场跑，讲义上只留脚本路径。
// 唯一留在讲义上的是*概念性*的表：它不是量出来的，是在解释一种结构。

#slide[
  #title[什么该留在 RAM]

  #chapterRef("2.") 把释放资源的人定了。这一章是开销的问题。
]

#slide[
  = 浏览器的数据不应该全部放进 RAM

  浏览器常驻之后，一个很自然的下一步是：把它的数据也放进 RAM。

  但「搬进内存更快」这个直觉，建立在一条假设上：文件在磁盘上，读它就要读盘；
  而内存占着就是占着。这条假设*两半都不成立*。
]

#slide[
  = 文件页是借来的，tmpfs 页是钉死的

  内核本来就会把读过的文件页留在内存里 —— 放在磁盘上，不等于每次都读盘。
  而且那些页随时收得回来：磁盘上那一份还在，下次读再拿。

  tmpfs 的页没有这一份。内存不够的时候，内核要么把它换回磁盘
  （那就等于绕一圈又回到磁盘），要么*把正在写它的人杀掉*。

  #note[
    现场跑：`./docs/labs/resident-browser/16-page-cache.sh`、
    `17-tmpfs-not-reclaimable.sh` —— 后者把 swap 一起关掉，
    看的才是「这一页有没有地方可去」。
  ]
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
  = 关窗之后进程数不会归零

  常驻实例还在，它那一整套 QtWebEngine 帮手也还在 —— 包括一个 renderer。
  它*没有*攥着任何已关闭的页面：它是等着下一个窗口的基础设施，
  而这正是常驻设计的目的（`pgrep -af QtWebEngineProcess`，关窗前后各数一次）。

  真正的验收标准不是「进程数归零」，是*生命周期*：主进程一退，整棵树跟着退。
]

#slide[
  #punch[
    将全部数据加载至 RAM 会产生不必要的开销，
    应结合存储层级与资源特性来制定存储方案。
  ]
]
