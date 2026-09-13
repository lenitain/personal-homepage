#import "../.course.typ": title, slide, punch, cols, note

#set document(title: "什么该留在 RAM（讲义）")

#slide[
  #title[什么该留在 RAM]

  #note[对应文档版第三章。完整版见 `3-what-deserves-ram.typ`。]
]

#slide[
  = 一个很自然、但是错的下一步

  浏览器常驻了，于是想把它的数据也放进 RAM。

  #punch[浏览器 profile 里的大部分字节是死的。]

  把它们拷进内存，你什么也没买到，
  只是永久性地占住了一块。
]

#slide[
  = 先把收益量出来

  ```sh
  冷启动 qutebrowser    1227 ms
  常驻   qb-open         232 ms
  ```

  消失的那一秒 = Python → Qt → WebEngine 链被重建。
  剩下的 230 ms = 你真正要求它做的事。

  现在的问题是：*别把买这一秒的内存浪费掉。*
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

  中间那行是钱所在的地方。
]

#slide[
  = 活的：只留增量

  最直觉的做法是登录时把整个 profile 拷进 tmpfs。

  *错的。* 因为一个 profile 里绝大多数文件，
  在一次会话里根本不会被碰 ——
  你会为「只被读过」的文件付内存。
]

#slide[
  = overlayfs

  - 底下：磁盘上的只读层
  - 上面：tmpfs 上的可写层
  - 从不写的文件 → 仍然从磁盘读
  - 第一次写 → *copy-up* 到 tmpfs

  每小时 resync 把增量写回磁盘备份。

  #punch[RAM 里放的是增量，不是 profile。]
]

#slide[
  = 量它（别打扰你在用的那个实例）

  自己一个 `XDG_RUNTIME_DIR`，把真实 socket
  *除 `qutebrowser/` 之外*全部软链过来 ——
  它什么都能连，但自己的 IPC socket 落在隔离目录里。

  ```sh
  空 profile，零窗口      136 MiB
  真实 profile，零窗口    140 MiB
  ```
]

#slide[
  = 差 4 MB

  一个天天在用的 12 MB profile，
  只有 4 MB 真的进了内存。

  #punch[这就是 overlayfs 在干活。]

  #note[我在这篇的上一版里写的是「零窗口 700 MB 到 1 GB」—— 凭印象写的，错了七倍。]
]

#slide[
  = 死的缓存一：shader cache

  QtWebEngine 每次启动都重写一份编译好的 shader 缓存。

  在 overlay 之下，「每次重写」= 「每次 copy-up 进 RAM」——
  又大又脏、无法回收，换来的是省下本来就不会重复的工作。

  ```sh
  c.qt.args = ["disable-gpu-shader-disk-cache"]
  ```
]

#slide[
  = ⚠️ 这笔交易有个前提

  *它只有在浏览器常驻之后才是免费的。*

  冷启动的话，你每次都要重新编译 shader，付的是实打实的时间。
  常驻之后 shader 一次会话只编译一次，磁盘缓存就没东西可省了。

  #punch[daemon 化这个决定，才是这条优化的前提。]
]

#slide[
  = 死的缓存二：HTTP 磁盘缓存

  这一份确实值得大，也确实该在磁盘上。

  - 几百兆（视频分片），可以重新抓取，LRU 淘汰
  - 名副其实的缓存

  在磁盘上它花的是 *page cache*，内核紧张时可以丢。
  放在 tmpfs 里它花的是*谁也回收不了的内存*。
]

#slide[
  = 一件看起来像泄漏、其实不是的事

  关掉所有窗口之后，还有一个 renderer 留在那儿。

  它*没有*攥着任何已关闭的页面 ——
  它是等着下一个页面的共享基础设施。

  #note[拿「关窗后进程数归零」当验收标准的话，你会一直以为这里有 bug。]
]

#slide[
  #punch[
    快不是「把所有东西都塞进 RAM」，
    而是分清哪些是活的、哪些是死的，只给前一种付内存。
  ]
]
