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
  = 把浏览器的数据也放进 RAM，是个错的直觉

  而且错在一个具体的地方：*浏览器 profile 里的大部分字节是死的*。
  把它们拷进内存，你什么也没买到，只是永久性地占住了一块。

  #punch[真正的问题是：哪些字节是活的。]
]

#slide[
  = 三种字节

  #table(
    columns: (1fr, auto, 1fr),
    table.header([种类], [该在哪], [为什么]),
    [活的（profile 写入）], [RAM], [热、小、必须持久],
    [死的缓存（shader / HTTP）], [磁盘], [可重建、大、冷],
    [页面状态（DOM / JS）], [关页即释放], [属于那个页面],
  )

  中间那一行是开销所在 —— 那两份缓存*看起来*都像是你会想放进 RAM 的东西。
]

#slide[
  = profile 只有几百 KB，开销不在这里

  一个天天在用的 profile，就算整份拷进内存，代价也就是这个量级。

  真正会把 RAM 吃掉的，是下面那两份缓存。

  #note[现场跑：`./docs/labs/resident-browser/12-resident-memory.sh`]
]

#slide[
  = overlayfs：RAM 里放的是增量

  - 底下：磁盘上的只读层
  - 上面：tmpfs 上的可写层
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

  冷启动的话，你每次都要重新编译 shader，付的是实打实的时间。
  常驻之后 shader 一次会话只编译一次，磁盘缓存就没东西可省了。
]

#slide[
  = HTTP 缓存该大，但不该在 RAM 里

  在磁盘上它花的是 *page cache*，内核紧张时可以丢掉；
  放在 tmpfs 里，它花的是*谁也回收不了的内存*。

  所以：设个上限，放在磁盘上，让内核决定这些页值不值得留着。
]

#slide[
  = 关窗后留下的 renderer 不是泄漏

  它*没有*攥着任何已关闭的页面 ——
  它是等着下一个页面的共享基础设施，而这正是常驻设计的目的。

  拿「关窗后进程数归零」当验收标准的话，你会一直以为这里有 bug。
]

#slide[
  #punch[
    快不是「把所有东西都塞进 RAM」，
    而是分清哪些是活的、哪些是死的，只给前一种付内存。
  ]
]
