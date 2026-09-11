# 重构：把 yazi 式浏览换成编辑器式「文件树 + 预览」

- 日期：2026-09-11
- 状态：待实施
- 影响范围：`src/` 的浏览逻辑与布局、`content/` 里两篇自述文案
- 不涉及：配色、字体、粉笔滤镜、构建配置（除测试）

## 背景

现在的浏览逻辑是 yazi 式的：左栏是**当前目录的平铺列表**，进目录就整栏换掉内容，右栏的预览跟着光标走，靠一个 `indexStack` 记住"从哪进来的"。

这套逻辑的问题是**没有全站视野**：访客在任何时刻只能看到一层，想找别的东西得先退出去；而且左栏内容会被替换掉，"我现在在树的哪个位置"全靠顶栏那行 `~ / content` 提示。

## 目标

左侧变成一棵**常驻的、可展开收起的文件树**（像代码编辑器的侧边栏），右侧只负责预览。

行为上按代码编辑器的语义：**光标和"已打开"是两件事**。↑/↓ 只移动光标，Enter 或单击才换内容。

## 已敲定的决策

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | 树的视觉语言 | 保留手写粉笔字（Kalam），但控件编辑器化：`▾`/`▸` 三角、等宽缩进、去掉 emoji 图标 |
| 2 | 默认展开状态 | **全部折叠**。首次进入只看到 5 个目录名 + `readme.md` |
| 3 | 光标移动是否换预览 | **不换**。光标只是光标，Enter / 单击才打开 |
| 4 | 键盘范围 | 只保留 ↑ / ↓ / Enter。Esc、←、→、Backspace 全部移除 |
| 5 | 顶栏 | **删除 `Header.svelte`**。路径信息移到状态栏 |
| 6 | 左栏整体收起 | **最左侧一条 22px 的窄边条常驻不动，它本身就是开关**：展开时显示 `«`（点它收起），收起时显示 `»`（点它展开）。不做"收起后换成另一个按钮"那套 |
| 7 | 展开状态的生命周期 | 纯内存。点开另一个目录**不会**收起先前展开的；收起再展开左栏，展开状态原样保留 |
| 8 | 不加快捷键 | 左栏开合只有鼠标按钮，不加 `\` / `Ctrl+B` |

## 不做什么

- URL 深链 / 每篇文章一个路由
- 搜索、过滤、标签
- 代码高亮、行号、面包屑
- 重命名仓库 / `package.json` 里的 `yazi-homepage`（名字留着）

## 窄视口（复盘后追加）

最初把移动端/窄窗口划在范围外（"现在是两栏硬挤，本次不改变这个现状"）。这是个误判：左栏是写死的 `280px`，窗口一旦窄到 344px 这种程度，右栏只剩 **25px**，文章被挤成每行一个字母，整页不可用。

断点 `640px`（脚本里的 `NARROW_VIEWPORT_QUERY` 必须和样式表里的 `@media` 保持一致）：

- **默认收起**：窄屏进场就是收起态，访客先看到文章；想看目录再点窄边条展开
- **树变浮层**：窄屏下 `.sidebar` 改成 `position: absolute` + `z-index: 10`，`width: min(280px, 85vw)`，加投影。它**脱离文档流**，所以不会挤压正文（正文保持满宽，被盖住而已）
- **选完即收**：窄屏下打开一篇文章会把树收起来，否则文章还被浮层盖着
- 窄边条在任何宽度下都保留，是开合树的唯一入口；窄屏下浮层的左边缘避让它 22px，免得把开关盖住

宽屏（> 640px）行为完全不变。

## 数据模型

### `src/lib/types.ts`

`FsEntry` 增加 `path`，并新增拍平后的行类型：

```ts
export interface FsEntry {
	/** 相对 content/ 的路径，如 'projects/dotfiles.md'；根节点为 ''。 */
	path: string;
	name: string;
	type: 'dir' | 'file';
	children?: FsEntry[];
	content?: string;
	mtime?: string;
}

/** flattenTree 的输出：树被拍平成一维后的一行。 */
export interface TreeRow {
	entry: FsEntry;
	/** 0 = 根的直接子节点 */
	depth: number;
	/** 仅对 dir 有意义 */
	expanded: boolean;
}
```

`path` 是这次重构的支点：它同时充当渲染 key、`expanded` 集合的成员、`findEntry` 的查找键。少了它，客户端得自己拼路径，容易出 bug。

### `src/routes/+page.server.ts`

- `readDir(dirPath, parentPath)` 递归，构造时顺手填 `path`
- **只保留 `.md` 文件**（同现在）
- **跳过递归后 `children` 为空的目录** —— 避免树里出现点了没反应的文件夹
- **排序：目录在前、文件在后，各自按 `name.localeCompare()`** 。`readdir` 的顺序不保证稳定，排序后树的顺序才是确定的（也让单测可写）
- 返回值从 `{ tree, initialIndex }` 改为 `{ tree, initialPath }`，`initialPath` 取根下的 `readme.md`，找不到则为 `null`
- 文章正文继续随树内联下发（8 篇小 md，不值得再开接口）

## 树的行拍平

新增 `src/lib/tree.ts`，三个纯函数：

```ts
export function flattenTree(root: FsEntry, expanded: Set<string>): TreeRow[]
export function findEntry(root: FsEntry, path: string): FsEntry | null
export function countFiles(root: FsEntry): number
```

`flattenTree` 是前序遍历：

```txt
walk(node, depth):
  if node 是 dir:
    if not expanded.has(node.path): return       // 根节点例外，永远展开
    for child of node.children:
      emit { entry: child, depth, expanded: expanded.has(child.path) }
      walk(child, depth + 1)
```

根节点自身不 emit —— 树的第一层就是 `depth = 0`。

**为什么拍平，而不是让 `Tree.svelte` 自递归**：↑/↓ 本来就是在"当前可见的行"上线性移动，拍平之后键盘逻辑就是 `rows[i ± 1]`，渲染也只是一个 `{#each}`，一份真相。递归组件更"正统"，但键盘要么去翻 DOM 顺序、要么另建一份拍平结果，两套真相迟早不一致。

## 客户端状态（`src/routes/+page.svelte`）

```ts
const tree = data.tree;
let expanded = $state(new SvelteSet<string>());   // 目录 path 集合，初始为空 = 全部折叠
let cursorPath = $state<string | null>(null);     // 键盘/鼠标光标
let openPath = $state<string | null>(data.initialPath); // 右栏正在显示的文章
let sidebarOpen = $state(true);

let rows = $derived(flattenTree(tree, expanded));
let openEntry = $derived(openPath ? findEntry(tree, openPath) : null);
let fileCount = $derived(countFiles(tree));
```

- `SvelteSet` 来自 `svelte/reactivity`，让 `$derived` 能追踪集合的增删
- **光标初始为 `null`**：进场时没有任何行是"光标态"，只有 `readme.md` 是"已打开"（橙色）
- **第一次按 ↑/↓ 时**：光标落到 `openPath` 那一行；若没有已打开的文章，落到第一行

## 交互规格

| 动作 | 结果 |
| --- | --- |
| 单击目录行 | 切换展开 / 收起；光标移到该行 |
| 单击文件行 | 打开（`openPath` = 它）；光标也移到该行 |
| ↑ / ↓ | **只**移动光标，右栏不变 |
| Enter（光标在目录） | 切换展开 / 收起 |
| Enter（光标在文件） | 打开 |
| ↑ / ↓ / Enter 且左栏已收起 | 全部忽略（避免"看不见的光标"在动） |
| 点窄边条 | 切换左栏开合。它永远在 `x = 0`、宽度不变，只有字形在 `«` / `»` 之间切 |

两个容易被漏掉的细节：

- 光标移到可视区外时，用 `scrollIntoView({ block: 'nearest' })` 把那行滚进来
- 若光标所在的行因为某个目录被收起而不再可见，光标回落到**那个被收起的目录行**上，不允许出现"光标悬空、按 Enter 没反应"的状态
- 换文章时右栏要回到顶部。实现上用 `{#key openPath}` 包住 `ContentPane`，换文件即重新挂载，滚动位置自然归零

键盘仍用**全局 `keydown` 监听**（跟现在一致），不做 roving tabindex。

## 组件改动

| 文件 | 动作 |
| --- | --- |
| `src/lib/tree.ts` | 新增。三个纯函数 |
| `src/lib/tree.test.ts` | 新增。vitest 单测 |
| `src/lib/components/FileTree.svelte` | 新增。吃 `rows` / `cursorPath` / `openPath`，吐事件 |
| `src/lib/components/FileList.svelte` | **删除**（被 FileTree 取代） |
| `src/lib/components/Header.svelte` | **删除** |
| `src/lib/components/ContentPane.svelte` | 改。删掉「目录就渲染文件列表」那段 yazi 的 Miller 行为，只剩 markdown 预览 + 空状态 |
| `src/lib/components/Status.svelte` | 改。左端加当前文章路径；右端改成全站文件总数；去掉 `parentCount` |
| `src/routes/+page.svelte` | 重写。新状态模型 + 新键盘处理 + 左栏开合 |
| `src/routes/+page.server.ts` | 改。见上 |
| `content/readme.md` | 改。键位表换成 ↑/↓ + Enter，措辞从 "file browser on the left" 改成树 |
| `content/projects/yazi-homepage.md` | 改。"Three-column yazi layout" 已经不成立，重写 Features 一节 |
| `package.json` / `vite.config.ts` | 加 `vitest`（devDependency）+ `npm run test` |

`vitest` 只测 `src/lib/tree.ts` 这三个不碰 Svelte、不碰 DOM 的纯函数，跑在 node 环境即可；`vite.config.ts` 里加一段 `test.include = ['src/**/*.test.ts']`，SvelteKit 插件照旧保留。

`content/blog/why-yazi.md` **不动** —— 它讲的是 yazi 这个工具本身，不是本站。

窄边条直接写在 `+page.svelte` 里，不单开组件：它就是一个按钮，没有独立状态。

## 视觉规格

- 外层：`height: 100vh` 纵向 flex —— `main`（横向 flex，`flex: 1`）+ `Status`
- 左栏：固定 `280px`、`flex-shrink: 0`；收起时整栏不渲染
- 窄边条：常驻 `main` 的最左端，宽 `22px`（`--rail-width`，窄屏浮层共用这个变量），底色 `--bg1`（跟状态栏同色），字形贴顶对齐第一行，hover 变 `--bg2`。树里不再有任何开合按钮
- 缩进：`padding-left: 6px + depth * 20px`。**层级只靠缩进表达，不画缩进参考线** —— 试过 1px 的版本，一来和粉笔手写的整体气质不搭（细得像条边框），二来很容易被看成一条多余的侧栏边界

  > 踩过的坑（记录一下，别再犯）：参考线一开始画在 `.file-tree` 面板上（`background-size: 1px 100%`）。面板是全高的，于是树只有 300px 内容时，线照样从面板顶拉到面板底，在最后一行下面留一条 600 多像素的悬空竖线。第二版改成按行画、只覆盖行高，位置是对了，但那个视觉问题依旧：一条 1px 的直线在黑板手写体旁边格格不入。结论是不画。
- 三角：`▾` 展开 / `▸` 收起，`--grey1`，固定宽 `1.1em`；文件行留同宽占位以对齐
- 目录名 `--green` 加粗；文件名 `--fg`
- **光标行**底色 `--bg3`；**已打开的文件**文件名 `--orange`（两者可叠加）
- 长文件名：`white-space: nowrap` + `text-overflow: ellipsis`
- 树文件名 `0.95em`，字体仍是 Kalam 手写体；右栏 markdown 样式不动

### ARIA

树的语义现在是错的（用的 `listbox` / `option`）。换成：

- 容器 `role="tree"`、`aria-label="content"`
- 行 `role="treeitem"`、`aria-level={depth + 1}`、目录另有 `aria-expanded`
- `aria-selected` 跟随光标

## 验证

1. `npm run check`（svelte-check）零错误
2. `npm run test`（`tree.ts` 的三个纯函数）
3. 起 dev server 手点一遍：

- [ ] 首屏：树全折叠（5 个目录 + `readme.md`），`readme.md` 显示为橙色，右栏是 readme 内容
- [ ] 点目录 → 展开出现子项；再点 → 收起
- [ ] 点文件 → 右栏换成该篇，橙色标记转移
- [ ] ↑/↓ 只动高亮，右栏纹丝不动；Enter 才切换
- [ ] 光标停在目录上按 Enter → 展开 / 收起
- [ ] 展开时点最左那条窄边条（显示 `«`）→ 左栏消失，窄边条原地不动、字形变 `»`
- [ ] 再点同一位置 → 左栏回来，之前展开的目录仍然展开着
- [ ] 开合两次，窄边条的 x 坐标始终是 0，正文宽度不跳动
- [ ] 左栏收起时按 ↑/↓/Enter → 无任何反应
- [ ] 状态栏：左边是当前文章路径，右边是文件总数
- [ ] 展开很深的目录后用键盘一路 ↓，行会被滚进可视区
- [ ] 换文章后右栏回到顶部
- [ ] 塞一个超长文件名，左栏不被撑破
- [ ] 窗口缩到 344px：进场直接读到文章，左栏只剩一条窄边条
- [ ] 344px 下点窄边条：树盖在文章上，且让开窄边条那 22px（不然开关被盖住就收不回来）
- [ ] 344px 下点一篇文章：浮层自动收起，文章可读
- [ ] 树里**没有任何竖线**：全部折叠时没有，展开后也没有；层级完全靠缩进读出来（子项比顶层缩进 20px）

## 风险

- `{#key openPath}` 会重建 `ContentPane`（marked 重新解析一次）。8 篇小文档，代价可忽略
- 删掉顶栏后没有面包屑，「我在哪」全靠状态栏那一行路径。左栏展开时树本身也提供了位置感
- `readdir` 顺序原本不确定，排序后行为变了 —— 这是**有意的**修正
- 若 `content/` 下一个 `.md` 都没有：`tree.children` 为空数组、`initialPath` 为 `null`，界面应落到空状态（右栏显示"select a file to preview"、树是空的），不能崩
