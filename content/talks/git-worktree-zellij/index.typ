#import "../../.course.typ": note, punch, slide, title

#set document(title: "让多个 agent 同时推进一个项目")

// 一条推理：串行慢 → 并行 → 并行会让多个 agent 改同一个文件 → 要各自的工作目录
// → branch 给不了，手动复制会多出几份历史 → worktree
// → 目录管不了进程 → zellij。
// 不写旁白，不用比喻，只留推理的每一步。

#slide[
  #title[为什么需要多 agent]

  随着模型和 agent 越来越擅长执行长程任务，
  agent 执行的耗时相较于任务规划的耗时越来越长。

  “后面10个需求我都想好了，可是第一个需求 agent 还没有开发完。”

  我们自然会想到，可以通过多 agent 同时工作来提高资源利用率。
]

#slide[
  #title[多 agent 开发的读写竞争]

  如果直接放任多 agent 同时工作？

  即便从功能的角度完全无关的需求，在代码层面也可能涉及到相同的文件。
  产生 *多个 agent 同时读写相同文件* 的问题。

  如果是实体的*硬件资源( CPU, IO )*，需要通过上锁等并发控制机制把资源竞争的部分串行化。
  但是项目文件是*数据对象*，可以直接复制，通过隔离转移竞争，保持并发。

  #note[没有不依靠语义理解就直接消除冲突的方法。冲突依然需要处理，只是把功能开发过程和冲突处理过程分开。]
]

#slide[
  #title[git branch]

  git branch 功能看上去有种“分叉分离”的感觉，但是做不到隔离。

  分支只是在提交图上给每条线一个名字。*提交图*分叉了，但磁盘上的*工作目录*始终只有一份，多个 agent 读写的仍然是同一批文件。

  隔离需要的是*多份工作目录*：文件分开之后，读写冲突不再存在，也就不需要上锁。
]

#slide[
  #title[复制整个项目目录]

  那么有什么方法能实现隔离？最容易想到的是复制。

  复制确实解决了写冲突：每个 agent 在自己那份目录里改，互不影响。
  但复制有两种拷法：

  - 连 `.git` 一起拷：历史被复制走了一份，不再共享。
    一边的提交另一边看不到，要手动 push / fetch；同一个分支在两份仓库里各有一个，会各自漂移。
  - 只拷项目文件、不带 `.git`：新目录不再是仓库，改完没法提交，也无法直接合并回来。

  复制的问题出在粒度上：复制是文件系统层面的动作，没有「工作区另存、`.git` 共用」的选项。
  要么历史各自管理，要么根本没有历史。

  并发开发需要的是*文件状态各一份，代码历史共享一份*。
]

#slide[
  #title[git worktree]

  `git worktree` 提供了*文件状态各一份，代码历史共享一份*的选项。
  在同一个仓库上挂出第二个工作目录：
  每个工作目录有自己的文件和暂存区，各自停在一个分支上；
  而对象库、全部分支的引用、远端配置都是仓库级的，只有一份。

  #table(
    columns: (auto, 1fr, 1fr),
    table.header([], [手动复制多份], [git worktree]),
    [代码历史], [每份各一套], [N 个目录共用一份],
    [一边刚提交的，另一边多久能看到], [先 push，再 fetch], [立刻 —— 本来就是同一份],
    [同一个分支], [每份各有一个同名分支，会各自漂移], [只能被检出一次，由 Git 挡住],
    [在一个目录里改另一个目录的代码], [要跨仓库，做不到], [直接改，本来就是同一个仓库],
  )
]

#slide[
  #title[agent 自带的 subagent]

  现成的多 agent 编排手段是 agent 自带的 subagent。

  subagent 可以分离上下文，但是没有分离控制流。主 agent 是内容发送和接收的唯一出入口：

  - “subagent 完成到什么程度了，我要如何查看？”
  - “subagent 好像改错内容了，但是我干预不了。”
  - “我定义了一套 subagent 工作流程的配置文件，但是每次的实际流程都和预期的有点偏差，每次都改配置文件不合理吧。”

  分离控制流是合理的需求，每件活各自有一个入口和一个出口会让流程灵活很多。
]

#slide[
  #title[把 agent 装进终端复用器]

  终端复用器可以把一个终端包装为*另一个终端可操作的对象*。

  那么把运行着 agent 的终端放入终端复用器中，就得到了*另一个 agent 可操作的 agent* (看上去这就是我们想要的控制流分离)。
]

#slide[
  #title[zellij 的常见命令]

  ```bash
  zellij a sub1                                     # 连接到现有的 sub1 会话
  zellij a -c sub1                                  # 创建 sub1 会话并进入
  zellij a -b sub1                                  # 在后台创建 sub1 会话

  zellij -s sub1 action write-chars 'echo hello'    # 往 sub1 会话标准输入写 'echo hello'
  zellij -s sub1 action send-keys Enter             # 往 sub1 会话标准输入执行 Enter
  zellij -s sub1 action dump-screen                 # 查看 sub1 会话标准输出的内容

  zellij k sub1                                     # 终止 sub1 会话中正在执行的程序
  zellij d sub1                                     # 删除 sub1 会话
  zellij ls                                         # 查看所有 zellij 会话的状态
  ```
]

#slide[
  #title[agent 和终端复用器的其他组合]

  并发任务的调度和编排只是 agent 和终端复用器的一种用法：

  - 串行编排：等 A 跑完，把它的结果写进 B 的终端。
  - 对抗：让 A 和 B 都使用 `grillme.skill` 互相拷问对方，把结果收敛为一份规划文档。
  - 先并行、后收口，或者中途把 review 换成第三个人。

  终端复用器之间没有「A 指向 B」这层固定关系。对象间的指针可以随提示词随时调转。
]

#slide[
  #title[和 subagent 结合]

  终端复用器只是工具，多 agent 编排依然可以参考现成的 subagent 流程。
  只是把 subagent 从 agent 内部的一个黑箱，换成一个可观测的终端。

  写成一条 skill 就够：

  ```text
  需要 subagent 时：zellij a -b <会话名>                              # 起一个后台会话
  让它开工：zellij -s <会话名> run --cwd <目录> -n <名字> -- pi -p "<任务>"   # 返回 pane id
  之后看进度、补指令：dump-screen / write-chars / send-keys，都带 --pane-id <id>
  ```

  自动化程度没降，还是 agent 自己决定什么时候派、派几个。
  但派出去的每一个都能直接操作，也可以被别的 agent 操作。
]

#slide[
  #punch[
    一个 agent 一份自己的工作目录（`git worktree`），

    一个 agent 一个自己的终端（`zellij`）。
  ]
]
