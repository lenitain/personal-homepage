#import "../.course.typ": title, slide, punch, cols, note

#set document(title: "谁来收尸（讲义）")

// 幻灯片版。和文档版的区别不在长短，在*切法*：
// 文档版按论证推进分段，一张幻灯片只承载一个「讲到这里要让人记住的点」。
// 所以这里的句子比文档版更短、更断言，细节留给讲的人说。

#slide[
  #title[谁来收尸]

  PID namespace 的四层失败

  #note[对应文档版第二章。左边文件树里 `2-who-kills-it.typ` 是完整版。]
]

#slide[
  = 常驻的账

  - 常驻 = 比启动它的东西活得更久
  - 一个 qutebrowser 不是一个进程，是*五个*
  - 所以欠的不是「关掉一个进程」
  - 是*收一整棵树的尸*
]

#slide[
  = 这笔账有个很坏的性质

  平时完全看不出来。

  - 开发时反复启动、反复关窗，一切正常
  - 只有注销之后，`ps` 里才发现一堆*没有爹的 renderer*
  - 而那时候你已经在做别的事了
]

#slide[
  = 我的第一反应

  ```sh
  unshare --pid --fork
  ```

  - namespace 的 init 一死，内核回收里面所有进程
  - 隔离和收尸，一个原语解决两个问题
  - 稳了
]

#slide[
  = 它不管用

  ```sh
  $ unshare --pid --fork --mount-proc true
  unshare: unshare 失败: 不允许的操作
  ```

  普通用户拿不到 PID namespace。

  *想用它，必须先建一个 user namespace。*
]

#slide[
  = 而 user namespace 会改掉你的身份

  ```sh
  $ unshare --user --pid --fork sh -c "id -u"
  65534
  ```

  - 空映射之下，内核拿 overflow uid 顶上
  - *默认状态是「你没有身份」，不是「你还是你」*
]

#slide[
  = 然后输入法没了

  浏览器一切正常：渲染、滚动、视频、快捷键。

  只有一件事不对：*打不出中文*。

  #punch[
    不是「转换不出来」，是「根本没接上」。
    这个区别决定了你往哪个方向查。
  ]
]

#slide[
  = 现场

  ```sh
  宿主上                    namespace 里
  AUTH EXTERNAL 31303030    AUTH EXTERNAL 3635353334
  → OK                      → REJECTED EXTERNAL
  ```

  - libdbus 用 `getuid()` 拼凭据 → 65534
  - broker 用 `SO_PEERCRED` 看内核报的 uid → 1000
  - 对不上，没有 session bus
]

#slide[
  = 为什么只有输入法坏？

  #cols[
    *Wayland*
    ```sh
    connect() 成功
    没有交换任何凭据
    → 2008 字节
    ```
  ][
    *D-Bus*
    ```sh
    要先认证
    第一件事就是自报身份
    → 身份已经变了
    ```
  ]

  namespace 打断的不是所有 IPC，
  而是*所有需要身份的 IPC*。
]

#slide[
  = 更尴尬的是：它连收尸都做不好

  ```sh
  $ kill -TERM $wrapper     → 没反应
  $ kill -KILL $wrapper     → wrapper 死了，里面还活着
  ```

  wrapper 和 namespace init 是两个进程，
  中间*没有任何东西转发信号*。

  于是补丁按固定顺序到来：`--kill-child` → 监督进程 → `PR_SET_PDEATHSIG`。
]

#slide[
  = 把需求重新说一遍

  不是「围住这棵树」，是两件具体的事：

  + 一个 *cgroup* —— 要扫掉哪些进程
  + *主进程跟踪* —— 有东西注意到主进程死了

  #punch[这两样东西，你的机器上已经有一个现成的实现，从开机起就在跑。]
]

#slide[
  = 那个实现就是 pid 1

  但它有个陷阱：niri 给每个 `spawn-sh` 都建了 cgroup，
  还带着 `KillMode=control-group`。看起来很接近。

  ```sh
  scope   MainPID=（空）
  service MainPID=100938
  ```

  *scope 没有主进程。* 没有主进程，就没有谁的死亡可以被注意到。
]

#slide[
  = 三种启动方式

  ```sh
  裸 setsid            → 子进程存活
  临时 scope           → 子进程存活
  临时 service         → 子进程已退出
  ```

  后两者的差别*只有一件事*：
  这个 cgroup 有没有把某个进程指定为主进程。
]

#slide[
  #punch[
    需要生命周期保证的时候，
    去找那个本来就管着生命周期的东西。

    隔离原语当不好 supervisor。
  ]
]

#slide[
  = 带走这一句

  一个错的工具如果当场就报错，你会立刻换一个。

  *它要是能用，你就会一直在它上面打补丁。*

  \# 这就是为什么「顺手」是最危险的选型理由
]
