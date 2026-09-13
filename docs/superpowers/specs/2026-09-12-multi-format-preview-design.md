# 预览层扩展：markdown 之外支持 typst / pdf

## 背景

右栏现在只会渲染 markdown，而且是两处硬编码的结果：

- `src/lib/content-tree.ts:32` —— `if (!dirent.name.endsWith('.md')) continue;`，非 `.md` 进不了树
- `src/lib/components/ContentPane.svelte:7` —— 拿到内容无条件 `marked.parse`，没有按类型分派

`content-tree.test.ts:56` 的用例名就叫「只要 .md，别的文件一概不进树」，把上面第一条锁成了预期行为。

要加的是两种新类型：**typst（`.typ`）** 与 **pdf（`.pdf`）**。本机 `typst` 已装在 `/usr/bin/typst`，版本 `0.15.1 (9dfd3a08)`。

## 目标

1. 三类文件可预览：`.md` / `.typ` / `.pdf`
2. `.typ` 显示**编译后的排版结果**，不是源码
3. 两类排版文档的文字**可选中**
4. 两类排版文档的文字**可检索，而且要两种方式**：浏览器自带的字符检索（Ctrl+F）与站内搜索栏
5. **移动端可用**
6. 两类排版文档统一到黑板的粉笔风格，且**不做风格开关，永远开着**

## 已敲定的决策

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | typst 预览的含义 | 编译后的排版结果 |
| 2 | 载体收敛 | 全站只有两种载体：**Markdown** 与 **PDF**。typst 编译成 PDF 后与 pdf 走同一条渲染路径 |
| 3 | 为什么不用 SVG | `--format svg` 的字是**字形轮廓**，实测整页 0 个 `<text>` 元素，文字不可选中（见「实测记录」A） |
| 4 | 为什么不用 typst 的 HTML 导出 | 实测 `#grid` / `#place` / `#rect` 被**静默丢弃**且 exit 0，用 `#grid` 排两栏的真实 CV 会渲染成空白（见「实测记录」B） |
| 5 | 为什么不用原生 iframe 嵌 PDF | 移动端不可用：Android 触发下载、iOS 只渲染第一页（见「实测记录」D） |
| 6 | 渲染器 | **pdf.js 的 viewer 层**（`pdfjs-dist/web/pdf_viewer.mjs`），不是只用它的渲染 API。理由：搜索、缩放、翻页、fit-width、可见区懒渲染都在这一层里现成（见「实测记录」E） |
| 7 | 两种检索都要 | **搜索栏**用 pdf.js 的 `PDFFindController`，抽文字、覆盖全部页；**浏览器 Ctrl+F 不拦截**，命中已渲染页。两者覆盖面不同，是分工不是重复（见「实测记录」F） |
| 8 | 两类文档的风格 | typst：**编译期**注入主题（页底、正文、链接、代码色）；现成 pdf：canvas 像素级处理，**反色时按对象豁免图像**（照片不变负片）。两者都常开，**不做开关** |
| 9 | 树的收录范围 | 只收 `.md` / `.typ` / `.pdf`；**点号开头的文件与目录一律跳过** |
| 10 | 缩放 / 翻页 / 页码 | **做**。viewer 层白拿，不自己写 |
| 11 | cMaps 与标准字体 | **自托管**：把 `pdfjs-dist/cmaps` 与 `pdfjs-dist/standard_fonts` 拷进 `static/pdfjs/`。不配这两项，非嵌入标准字体与非嵌入 CJK 字体的 PDF 会缺字（见「风险」） |
| 12 | 全站搜索（跨文件检索） | **不做**。这是另一个功能（要索引、结果列表、与「只靠文件树导航」的模型对接），该有自己的 spec —— 不是被这次含糊掉的 |

> 决策 7 与 12 是上一版 spec 的一处错误修正。上一版用「站内搜索框」一个词同时指着「文档内查找」和「全站搜索」，然后把两者一起否掉了：前者是 viewer 能力、成本很低，后者才是另一个功能。措辞含糊导致决定含糊。

## 不做什么

- 图片 / txt / 其他类型的预览（树里也不显示）
- typst 源码视图（决策 1 已排除）
- **全站搜索**（决策 12）—— 明确留作独立功能，不是遗漏
- **PDF 的逐对象风格化（文字/标题级）** —— 做不到：文字层只提供「文字片段 + 坐标」，没有「这是标题」「这是段落」这种语义，所以没法让"标题变绿、正文换手写体"。**能按对象豁免的只有图像**（决策 8），而矢量色块、图表线条、表格边框与文字在 PDF 里是同一种东西（矢量算子），无法区分对待
- 打印 / 下载 / 缩略图侧栏等 viewer 全套功能

## 实测记录

写下命令与结果，免得后人重走一遍。

### A. typst 的 SVG 没有文字对象

```sh
typst compile --format svg doc.typ 'out/page-{p}.svg'
```

- 多页时输出路径**必须**带 `{p}` 模板，否则 `error: cannot export multiple images without a page number template`
- 产出的 SVG 用 `<symbol>`（字形轮廓）+ `<use xlink:href="#gXXXX">` 组装文字：`grep -c '<text'` = **0**
- ID 是字形内容的哈希，两个不同文档里同一个字形的 ID 完全一致 ⇒ 内联到同一 DOM 不会撞坏
- 结论：不可选中，**弃用**

### B. typst 的 HTML 导出会静默丢内容

```sh
typst compile --features html --format html doc.typ out.html
```

| typst 构造 | HTML 导出结果 |
| --- | --- |
| 段落 / heading / list / table / strong / link / 代码高亮 | 正常，语义标签齐全 |
| `#grid(columns: ...)` | **body 0 字符，exit 0** |
| `#place` | **body 0 字符，exit 0** |
| `#rect` | **body 0 字符，exit 0** |
| `#grid` + 段落 | 只留段落，grid 部分**无声消失** |
| `#set page(fill:)` | 被忽略，仅 `warning: page set rule was ignored during HTML export` |

`#grid` 是 typst 排两栏 CV 的标准写法，而导出器对此只给 `warning: html export is under active development and incomplete`。**最糟的失败模式（内容消失且不报错），弃用。**

### C. typst 的 PDF 是真文字

```sh
typst compile --format pdf cv.typ cv.pdf && pdftotext cv.pdf -
```

`pdftotext` 把 `#grid` 两栏里的内容**完整**提取出来（`Lenitain` / `Backend / Infra` / `Experience` / `• Yazi — terminal file manager contributor` / `Projects` / `dotfiles` …）。PDF 结构里 6 个 `/Type /Font`、2 张 `/ToUnicode` 表、14 个文本显示算子 —— 是可选中、可提取的真文字。**采用。**

### D. 移动端 iframe 的实测结论来源

[How to Embed PDF in HTML](https://www.dynamsoft.com/codepool/how-to-embed-pdf-in-html.html) 的对比结论：`<iframe>` 在移动端 **Android 触发下载、iOS 只渲染第一页**，并建议用 JS viewer 换取一致的跨端行为。

### E. pdf.js 的 viewer 层确实发货，且自带我们要的东西

`pdfjs-dist@6.3.289`，包内**没有** `exports` 映射，深路径导入合法：

| 路径 | 体积 | 用途 |
| --- | --- | --- |
| `build/pdf.min.mjs` | 458 KB | 主入口，导出 `getDocument` / `TextLayer` / `AnnotationLayer` / `GlobalWorkerOptions` |
| `build/pdf.worker.min.mjs` | 1.26 MB | worker，用 `?url` 导入后赋给 `GlobalWorkerOptions.workerSrc` |
| `web/pdf_viewer.mjs` | 320 KB | viewer 层，实测导出 `PDFViewer` / `EventBus` / `PDFLinkService` / `PDFFindController` / `LinkTarget` |
| `web/pdf_viewer.css` | 163 KB | textLayer / annotationLayer / highlight 的定位与样式 |

合计约 2.2 MB，**动态 import 懒加载**：只看 markdown 的访客不付这笔钱。

接线方式有[官方风格的完整示例](https://www.nutrient.io/blog/pdfjs-react-viewer-setup/)：`EventBus` → `PDFLinkService` → `PDFFindController` → `PDFViewer`，再 `setDocument`。该文还有一条对我们直接相关的提示：**面板尺寸可变的场景要调 `viewer.update()`** —— 我们的侧栏开合就是 160ms 的宽度动画。

### F. 两种检索的覆盖面不一样（决定「两个都要」）

读 `web/pdf_viewer.mjs` 源码：

- `DEFAULT_CACHE_SIZE = 10`，缓冲区按 `max(10, 2 × 可见页 + 1)` 调整（`#buffer.resize(newCacheSize, visible.ids)`）。**缓冲外的页会被销毁**，canvas 与文字层一起移除
- ⇒ **浏览器 Ctrl+F 只能命中视口附近约 10 页内的文字**，再远就没有 DOM 文字可匹配
- `PDFFindController` 走 `_extractText` / `getTextContent`，**从文档里抽文字，不依赖渲染**
- ⇒ **搜索栏能命中全部页**，并驱动 viewer 把目标页渲染出来、滚过去、打高亮

两者互补：Ctrl+F 是"眼前这页里找"，搜索栏是"整份文档里找"。缓冲区大小是写死的常量、没有公开选项暴露它 —— 所以 Ctrl+F 的覆盖面是 pdf.js 的既有行为，不是我们的选择。

## 数据模型

### `src/lib/preview-kind.ts`（新增，纯函数）

```ts
export type PreviewKind = 'markdown' | 'typst' | 'pdf';

/** 按扩展名判定预览类型；不认识就返回 null。 */
export function previewKindOf(name: string): PreviewKind | null {
	const dot = name.lastIndexOf('.');
	if (dot === -1) return null;
	switch (name.slice(dot).toLowerCase()) {
		case '.md': return 'markdown';
		case '.typ': return 'typst';
		case '.pdf': return 'pdf';
		default: return null;
	}
}
```

**服务端拿它过滤建树，客户端拿它分派渲染器** —— 同一个函数，就不会出现「树里有、点开不认识」的错配。扩展名比较统一转小写，`README.MD` 也算 markdown。

### `src/lib/types.ts`（改）

```ts
export interface FsEntry {
	path: string;
	name: string;
	type: 'dir' | 'file';
	children?: FsEntry[];
	/** 只有 markdown 内联正文；typst/pdf 留空，内容走各自的 HTTP 路由。 */
	content?: string;
	/** 文件字节数（stat.size）。目录没有这个字段。 */
	size?: number;
	mtime?: string;
}
```

不新增 `kind` 字段：类型由 `previewKindOf(entry.name)` 现算，避免同一件事存两份。

## 建树（`src/lib/content-tree.ts` 改）

1. 白名单从 `.md` 换成 `previewKindOf(dirent.name) !== null`
2. **跳过点号开头的文件和目录** —— typst 编译的 wrapper 是隐藏文件，必须不进树
3. `size` 取 `stats.size`（真实字节数）
4. **只有 markdown 继续内联 `content`**：pdf 是二进制、不能进 SSR 载荷；typst 不需要源码
5. 「一篇都没有的目录整支丢弃」规则不变

## 服务端路由

| 路由 | 用途 | 响应 |
| --- | --- | --- |
| `GET /raw/[...path]` | 现成 pdf 的原始字节 | `200` `application/pdf` + `Content-Disposition: inline` + `ETag` / `Last-Modified` + `Cache-Control: no-cache`；白名单**只有 `.pdf`** |
| `GET /typst/[...path]` | typst 编译后的 pdf | `200` `application/pdf` + `ETag: "<deps hash>"` + `Cache-Control: no-cache` |
| | | `422` `application/json` `{ error: string, diagnostics: string[] }` —— 编译失败 |
| | | `404` —— 文件不存在 / 扩展名不在白名单 / 路径穿越 |

两条路由共用 `resolveContentPath`（见下）与同一套 404 语义。`ETag` 用 deps 哈希，浏览器缓存因此自动失效：内容没变就 304，变了就重新编译。

**为什么 `/typst` 一个路由同时给文档和错误**：客户端的流程本来就是「fetch → 先看 `response.ok` → 正常就把 `arrayBuffer` 交给 pdf.js，报错就渲染诊断面板」，一个 URL 一条流程。这是最初设想的多页 SVG + manifest + `?page=N` 方案简化后的结果 —— 产出物从「N 个 SVG」变成一个 pdf，页数也改由 pdf.js 的 `numPages` 提供，manifest 整个不需要了。

## typst 编译（`src/lib/typst-compile.ts` 新增，仅服务端）

### wrapper

在**文档同目录**写一个隐藏 wrapper，编译完在 `finally` 里删掉。只有同目录才能让文档里的相对 `#include`、`#image` 按原样解析：

```typst
#set page(fill: rgb("#2D353B"))
#set text(fill: rgb("#D3C6AA"))
#show link: set text(fill: rgb("#7FBBB3"))
#show raw:  set text(fill: rgb("#E67E80"))
#include "cv.typ"
```

文件名形如 `.preview-<随机>.typ`。这些 `#set` 会成为被 include 内容的默认样式；文档内部自己指定的颜色、图表、图片保持原样 —— 站点的主题只接管「默认正文色 + 页底色」，这是「typst 只是后端、前端可插拔」的具体落法。

### 命令

```sh
typst compile --format pdf --root . \
  --deps <tmp>/deps.json --diagnostic-format short \
  '.preview-xxxx.typ' '<tmp>/out.pdf'
```

`execFile('typst', args, { cwd: CONTENT_DIR, timeout: 10_000, maxBuffer: 1MB })`。`cwd` 设在 `content/`，deps 里的路径就是相对 `content/` 的，省一层换算。

### 三个实测得来的机制

- **缓存键**：`deps.json` 的 `inputs` 列出真实依赖（被 `#include` 的片段、引用的图片），拿它们的 `mtimeMs + size` 排序后 sha256 → 缓存键。改文档**或改它 include 的片段**都会失效，不用自己猜依赖图
- **失败**：`--diagnostic-format short` 给一行式诊断（`broken.typ:2:8: error: expected expression`），返回前把 wrapper 的临时文件名替换回原文件名，不泄露内部实现
- 页数不再需要从 `outputs` 数 —— pdf.js 自己知道

### 缓存

`Map<文档相对路径, { inputs: string[], hash: string, pdf: Buffer, at: number }>`。

命中判定：先按上次记录的 `inputs` 逐个 `stat` 重算哈希，一致就返回缓存的 Buffer，不一致就重编译（重编译会刷新 `inputs`）。新增依赖的情况也正确 —— 加了 `#include` 就必然改了文档自身，文档的 mtime 变了就会重编译。

按总字节数设上限（建议 64 MB），超了淘汰最旧的。

### 主题色常量

`typst-compile.ts` 顶部集中定义，注释指向 `src/routes/+layout.svelte`：

| 注入项 | 值 | 对应 CSS 变量 |
| --- | --- | --- |
| 页底 | `rgb("#2D353B")` | `--bg0` |
| 正文 | `rgb("#D3C6AA")` | `--fg` |
| 链接 | `rgb("#7FBBB3")` | `--blue` |
| 代码 | `rgb("#E67E80")` | `--red` |

服务端读不到 CSS 变量，所以这 4 个值是**有意的重复**；改主题色要同步两处（见「风险」）。

## 路径安全

### `src/lib/content-path.ts`（新增，纯函数 + 单测）

```ts
/** 把 URL 里的相对路径解析成 content/ 下的绝对路径；任何不合规都返回 null。 */
export function resolveContentPath(contentDir: string, urlPath: string): string | null;
```

拒绝规则：

1. 空串、空段（`a//b`）、`.` 与 `..` 段
2. 绝对路径（以 `/` 开头）、含 NUL 字节
3. 扩展名不在白名单（`/raw` 用 `.pdf`，`/typst` 用 `.typ`，同一实现参数化）
4. `path.resolve` 之后**仍必须**以 `contentDir + path.sep` 为前缀 —— 这是最后一道闸

**为什么抽成纯函数**：这是整个改动唯一的安全边界，必须能单测，不能只靠手点。

### SvelteKit 的约束（记录，免得再撞）

rest 参数 `[...path]` 必须是**最后一段**，所以 `[...path]/[page]` 这种嵌套**不合法**。这也是「一个 `/typst` 路由 + 客户端一条流程」比「manifest + 每页一个 URL」更省事的原因之一。

## 客户端

### 分派（`ContentPane.svelte` 改）

```svelte
{#if kind === 'markdown'}   <!-- 原 marked 路径，一行不改 -->
{:else if kind === 'typst'}
	<DocumentViewer url="/typst/{entry.path}" tone="chalk" title={entry.name} />
{:else if kind === 'pdf'}
	<DocumentViewer url="/raw/{entry.path}" tone="invert" title={entry.name} />
{:else}
	<div class="empty">select a file to preview</div>
{/if}
```

`{#key openPath}` 已经保证换文件即重新挂载，viewer 的内部状态不用手动清理。

### `src/lib/components/DocumentViewer.svelte`（新增）

props：`{ url: string, tone: 'chalk' | 'invert', title: string }`。

按 viewer 层的官方接线方式组装，四件套一个都不能少：

```ts
const pdfjs = await import('pdfjs-dist/web/pdf_viewer.mjs');   // 动态 import，SSR 阶段不碰
const eventBus = new pdfjs.EventBus();
const linkService = new pdfjs.PDFLinkService({ eventBus, externalLinkTarget: pdfjs.LinkTarget.BLANK });
const findController = new pdfjs.PDFFindController({ linkService, eventBus });
const viewer = new pdfjs.PDFViewer({ container, eventBus, linkService, findController });
linkService.setViewer(viewer);
// setDocument 三处都要接：linkService / findController / viewer
```

要点：

1. `fetch(url)` → 不 ok 就按 content-type 解析 JSON 诊断，渲染报错面板（`.typ` 的编译错误走这里）；ok 就 `arrayBuffer()`
2. worker：`import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'` → `GlobalWorkerOptions.workerSrc = workerUrl`，**必须在加载文档前设好**
3. `cMapUrl` / `standardFontDataUrl` 指向自托管的 `static/pdfjs/{cmaps,standard_fonts}/`（决策 11）
4. `pagesinit` 事件里设 `viewer.currentScaleValue = 'page-width'`
5. **卸载时 `loadingTask.destroy()` + `pdfDocument.destroy()`** —— 换文件会重新挂载，不销毁会漏 worker
6. 侧栏开合结束后调 `viewer.update()`（官方提示的 resizable panel 处理）
7. 可见区懒渲染是 viewer 层自带行为，**不自己写 IntersectionObserver**

三态：**加载中 / 报错面板 / 页面**。

### `src/lib/components/DocumentToolbar.svelte`（新增）

一条细长的粉笔风工具条，纯展示组件（状态由 DocumentViewer 持有，回调上传）：

| 控件 | 行为 |
| --- | --- |
| 搜索输入框 | 输入即搜 → 向 `eventBus` 派发 `find` 事件；回车 = 下一个、Shift+回车 = 上一个（`again`） |
| 命中计数 | 订阅 `updatefindmatchescount` / `updatefindcontrolstate`，显示 `3 / 17` |
| 缩放 | `-` / `+` 按 1.2 / 0.8 乘 `currentScale`；`fit` 复位到 `page-width` |
| 页码 | `pagechanging` 事件更新，显示 `3 / 8` |

**find 事件的契约**（读 `web/pdf_viewer.mjs` 源码确认，不要凭记忆写）：

```ts
// 新搜索：type 传空串
eventBus.dispatch('find', {
  source, type: '', query,
  caseSensitive: false, entireWord: false, matchDiacritics: false,
  highlightAll: true, findPrevious: false
});
// 下一个 / 上一个：type 传 'again'，上一个再把 findPrevious 置 true
// （不是 'findagain' —— 那是老版本的名字，写错了会落进兜底分支）
```

- `#onFind(state)` 实际读的字段就是 `type` / `query` / `caseSensitive` / `entireWord` / `findPrevious` / `highlightAll`。**没有 `phraseSearch`** —— 这个版本里不存在，别照抄老教程
- `source` 这个版本的 `#onFind` **不校验**，传一个稳定对象即可（pdf.js 自己传的是 find bar 实例）
- 命中计数来自 `updatefindmatchescount` 的 `event.matchesCount.current` / `.total`
- 控制状态来自 `updatefindcontrolstate` 的 `event.state`（`FOUND: 0` / `NOT_FOUND: 1` / `WRAPPED: 2` / `PENDING: 3`）与 `event.previous`
- **工具条不自己加防抖**：`#onFind` 内部对新搜索已有 `#findTimeout` 延迟调度，再叠一层只会让输入更迟钝。实测打字卡顿再补

高亮由 pdf.js 自己画（源码里 `className = "highlight middle" + highlightSuffix`，样式已在 `pdf_viewer.css` 里），**不自己实现高亮**。

**不拦截 Ctrl+F**：不注册、不 `preventDefault`，浏览器自带的查找栏照常打开、照常在文字层上匹配（决策 7）。

### 一个会被这次改动引爆的既有 bug（顺手修）

`+page.svelte:104` 的全局 `keydown` 监听**没有检查事件来源**。搜索框一出现，在里面打字就会：↑/↓ 移动文件树光标、Enter 打开文件 —— 打字把树搅乱。

修法：`handleKeydown` 开头判断事件目标，落在 `input` / `textarea` / `[contenteditable]` 上就 `return`。这一条必须在接搜索框之前修掉，否则手点验证会被它干扰到没法判断别的功能是否正常。

## 视觉规格

### 滤镜落位（`+page.svelte` 改）

现在 `filter: url(#chalk-writing)` 套在 `.content-pane` **整栏**上（`+page.svelte:209-213`）。改成：

| 目标 | 滤镜 |
| --- | --- |
| markdown `article` | `url(#chalk-writing)`（不变） |
| typst 的 canvas | `url(#chalk-writing)`（文档在编译期已经是暗底粉笔色，只补颗粒） |
| pdf 的 canvas | 元素上只留 `url(#chalk-writing)`（颗粒）；**颜色变换（invert / hue-rotate / sepia / brightness）改在 canvas 合成阶段用 `ctx.filter` 做**，这样图像区域能被豁免（见下） |
| 工具条 | `url(#chalk-writing)`（跟状态栏一致） |
| 文字层 | **不套** —— 它本身透明，套了只会让选中高亮变糊 |
| 整个 `.content-pane` | **不套** |

两条理由：SVG turbulence 滤镜在大滚动区上会反复重栅格化，多页文档会掉帧 —— 改成**按页**套；而套在 iframe 上只会把原生 viewer 的工具栏一起糊掉、底色却还是白的（这是上一版决定用 iframe 时的遗留问题，现在 iframe 没了，规则一并收紧）。

### 现成 pdf 的整页风格化：图像对象豁免反色

实测（ImageMagick 近似 CSS 的 `invert(1) hue-rotate(180deg)`）：白底页 mean=0.998 → 处理后 0.0035，暗底亮字成立，粉笔颗粒可再叠。

**但整页反色会把照片变成负片 —— 这一点可以避免**，因为图像在 PDF 里是**可定位的对象**：

1. `page.getOperatorList()` 拿绘制算子序列，跟踪 `OPS.save` / `OPS.restore` / `OPS.transform` 维护 CTM
2. 遇到 `OPS.paintImageXObject` / `paintInlineImageXObject` / `paintImageMaskXObject` / `paintImageXObjectRepeat` 时，把当前 CTM 作用到图像的单位方框，得到设备空间矩形（多个矩形取并集）
3. 颜色变换**不放在元素上**，改成合成阶段用 `ctx.filter` 做：把页面 canvas 带滤镜画进一张新 canvas，再把图像矩形**不带滤镜**地从原 canvas 盖回去
4. 元素级 CSS filter 只剩 `url(#chalk-writing)` 的颗粒 —— 颜色已经烘在像素里了

这条路径只用公开 API（`OPS` 与 `getOperatorList` 都在主入口导出，算子名实测确认），代价是几十行 CTM 跟踪。

**验收标准**（不是像素级匹配，是观感）：页底接近 `--bg0`、正文接近 `--fg`、**照片保持原样**、看不出明显负片感。滤镜参数在实现时对着真实 pdf 调。

**仍然做不到的**（写进「风险」，不假装解决）：**矢量色块、图表线条、表格边框与文字在 PDF 里是同一种东西**，无法区分「这是标题色」和「这是品牌色」，所以它们**仍会被反色** —— 要做到那一层只能走 typst 那条编译期路线（源码可控）。另有两处近似，都要接受：旋转 / 裁剪 / 带遮罩（SMask）的图像按**包围盒**处理，边界可能略有出入；算子列表解析异常时**回退整页反色**，绝不让页面渲染不出来。

### 文字选中

pdf.js 的文字层是真实 DOM 文字，选中由它保证。选中高亮的配色跟着站点的 `::selection`（`--bg3` 底 / `--fg` 字）走，落在暗底页面上可见；若实测对比不足，在 viewer 内覆盖 `.textLayer ::selection` 单独加一档对比。

工具条按站点的粉笔语言做：Kalam 手写体、`--bg1` 底、`--grey1` 次要文字、输入框透明底 + `--bg4` 下边框，高度压在 `1.8em` 以内，不抢正文。

## 组件改动

| 文件 | 动作 |
| --- | --- |
| `src/lib/preview-kind.ts` | 新增。扩展名 → 预览类型，前后端共用 |
| `src/lib/preview-kind.test.ts` | 新增。单测 |
| `src/lib/content-path.ts` | 新增。路径解析 + 白名单，纯函数 |
| `src/lib/content-path.test.ts` | 新增。穿越 / 空段 / NUL / 非白名单 |
| `src/lib/typst-compile.ts` | 新增。wrapper 注入、调 typst、deps 缓存、诊断清洗 |
| `src/lib/typst-compile.test.ts` | 新增。真调 typst 跑临时 fixture |
| `src/lib/content-tree.ts` | 改。三类白名单、跳点号、`size`、只内联 markdown |
| `src/lib/content-tree.test.ts` | 改。「只要 .md」那条断言扩成三类 + 点号 + `size` |
| `src/lib/types.ts` | 改。`FsEntry` 加 `size` |
| `src/routes/raw/[...path]/+server.ts` | 新增。pdf 字节 |
| `src/routes/typst/[...path]/+server.ts` | 新增。编译后的 pdf / 422 诊断 |
| `src/lib/components/DocumentViewer.svelte` | 新增。pdf.js viewer 层接线，两类文档共用 |
| `src/lib/components/DocumentToolbar.svelte` | 新增。搜索 / 缩放 / 页码，纯展示 |
| `src/lib/components/ContentPane.svelte` | 改。按 kind 分派；markdown 样式与滤镜落位 |
| `src/lib/components/Status.svelte` | 改。`size` 改用 `entry.size`，B/K/M 正常进位 |
| `src/routes/+page.svelte` | 改。滤镜下沉到 article；`handleKeydown` 忽略输入框来源 |
| `static/pdfjs/{cmaps,standard_fonts}/` | 新增。从 `pdfjs-dist` 拷入（决策 11） |
| `package.json` | 加 `pdfjs-dist` 依赖 |
| `content/cv.typ` + `content/cv.pdf` + 一张小图 | 新增。**占位样例**，跑通链路用：带一张图是为了同时验「图像豁免反色」和「typst 的相对 `#image()` 解析」。之后换成真文件 |

`package.json` 的 `pdfjs-dist` 放 `dependencies`（运行时要用），不是 devDependencies。

### 状态栏的顺带修复

`Status.svelte:18` 现在用 `entry.content?.length` 当字节数 —— 对 markdown 是**字符数**、对二进制是错的。改用 `entry.size`。`meta` 那格 `{ext} file` 保持原样（`typ file` / `pdf file` 读得通）。

## 测试

`vitest` 只跑 `src/**/*.test.ts` 的纯逻辑（`vite.config.ts` 既有约定），组件仍靠手点。

- `preview-kind.test.ts` —— 三种扩展名、大小写、无扩展名、`.mdx` / `.markdown` 这类近似值必须返回 null
- `content-path.test.ts` —— 编码后的穿越、`a/../b`、绝对路径、NUL、`.png` 非白名单、正常嵌套路径
- `content-tree.test.ts` —— 三类都进树、`.png` 不进、点号文件/目录不进、目录 size 不设、markdown 仍内联 content、typst/pdf 的 content 为 undefined
- `typst-compile.test.ts` —— 临时 fixture 真调 typst，只断言这些能稳定断言的事：编译成功返回以 `%PDF` 开头的非空 Buffer、语法错误返回诊断且**不含 wrapper 的临时文件名**、wrapper 文件编译后被删除（fixture 目录里不再有 `.preview-*.typ`）、第二次调用命中缓存（不重新 spawn：拿编译产物的对象引用或 `mtimeMs` 判定）

整组用 `describe.skipIf(!hasTypst)` 包住（`hasTypst` 用 `spawnSync('typst', ['--version'])` 判定），换一台没装 typst 的机器不至于整片挂掉。

viewer 层与工具条是 DOM/Svelte 世界的东西，按既有约定不写单测。

## 验证

1. `npm run check`（svelte-check）零错误
2. `npm run test`
3. 起 dev server 手点：

**markdown 与建树**

- [ ] markdown：点开 `readme.md`，观感与改动前**逐像素一致**（滤镜下沉后不能变糊或变清）
- [ ] 树里出现 `cv.typ` 与 `cv.pdf`；非三类的文件（临时塞一个 `.png`）不出现
- [ ] 状态栏：pdf 显示真实字节数（不再是字符数）

**typst**

- [ ] 点开 `content/cv.typ`，出现暗底粉笔页；内容与 `content/cv.pdf` 的排版一致（两栏、表格、彩色分隔线都在）
- [ ] 文字**能拖选**，选中高亮与文字重合（错位就说明文字层的 scale/尺寸没接好）
- [ ] 多页文档滚到底，页数与内容正确；滚动时内存不随页数线性增长（viewer 的缓冲在起作用）
- [ ] **编译错误**：故意在 `cv.typ` 里写 `#let x =`，右栏出现诊断面板且只报真实文件名与行号，不出现 `.preview-xxxx.typ`
- [ ] 修好后重新打开能恢复，不需要重启 dev server；改一个被 `#include` 的片段，预览跟着变

**pdf**

- [ ] 点开 `content/cv.pdf`，白底被整页转成暗底亮字
- [ ] **图像豁免**：样例 pdf 里那张小图 → 正文变亮字，**图保持原样**、没变负片
- [ ] **矢量色块仍反色**：同一份 pdf 里的彩色标题条 / 图表会反色 —— 已知边界，确认观感可接受
- [ ] 算子列表解析失败时回退整页反色，页面仍正常显示（临时改坏解析逻辑验一次）
- [ ] 文字能拖选；文档里的链接可点（`LinkTarget.BLANK` 走新标签）

**两种检索（决策 7 的核心）**

- [ ] **搜索栏**：搜一个**只出现在第 8 页**的词 → 命中计数正确、能跳过去、目标页被渲染出来并高亮
- [ ] 搜索栏搜一个不存在的词 → 显示 `0 / 0`，不报错
- [ ] **浏览器 Ctrl+F**：在**当前可见页**上搜一个词 → 浏览器查找栏命中并高亮
- [ ] **Ctrl+F 的边界**：搜一个只出现在远处页的词 → 命不中（预期行为，文字层未渲染）。这一条要确认它**不报错、不崩**，只是没命中
- [ ] 搜索框里打字时，文件树的 ↑/↓/Enter **纹丝不动**（既有 bug 已修）
- [ ] 焦点在搜索框时按 Enter → 跳下一个命中，而不是打开文件树里的文件

**布局与移动端**

- [ ] 侧栏开合（pane 宽度 160ms 动画）后，页面重新 fit-width，不出现横向滚动条
- [ ] 窄视口（≤640px）：pdf/typst 页面 fit-width；树浮层行为不变
- [ ] 手机（或 DevTools 移动模拟）上打开 pdf：能渲染、能选中、能用搜索栏 —— 这是本次改动的主要动机，必须真机或模拟器验
- [ ] 中文 pdf：塞一份中文 pdf，字形不缺、不乱码（验决策 11 的 cMaps / 标准字体是否真的接对了）

**其他**

- [ ] `curl --path-as-is -i 'localhost:5173/raw/../../etc/passwd'` 与编码变体一律 404，不返回文件（**必须带 `--path-as-is`**，否则 curl 自己就把 `..` 归一化了，测的是空气）
- [ ] `curl -i localhost:5173/raw/readme.md` → 404（白名单只有 pdf）
- [ ] 只看 markdown 时，Network 面板里**没有** pdf.js 的 chunk（懒加载生效）
- [ ] 连续切换文件 10 次，DevTools 里 worker 数量不增长（卸载时 destroy 生效）

## 实现记录（2026-09-12，与设计的偏差）

实现完成，`npm run check` 0 错误、`npm run test` 55 个用例全绿。以下是与设计不一致或设计里没写到的地方 —— 前两条是**照抄网上示例必然踩的坑**，只有真跑浏览器才能发现。

| # | 事项 | 结论 |
| --- | --- | --- |
| 1 | viewer 层的加载契约 | `web/pdf_viewer.mjs` 是**独立 bundle**，第 1960 行直接 `const {...} = globalThis.pdfjsLib`。必须先把核心模块挂到 `globalThis.pdfjsLib` 再 import 它，否则 `Cannot destructure property 'AbortException' of 'globalThis.pdfjsLib'`。那篇搭建指南的片段漏了这步 |
| 2 | 容器的硬性要求 | 构造 `PDFViewer` 时若容器有 `offsetParent` 而 `position` 不是 `absolute`，直接抛 `The 'container' must be absolutely positioned.`。所以 DOM 是「relative 外壳 + absolute 滚动容器 + `.pdfViewer`」三层 |
| 3 | find 事件类型 | 是 `'again'` 不是 `'findagain'`（本 spec 原文写错，已改）。写错会落进兜底分支：选中会跳，但高亮与计数不按预期刷新 |
| 4 | 命中计数 | 不用 `updatefindmatchescount` 的载荷：pdf.js 在 `PENDING` 阶段就派发它，那时 `_selected` 还是**推进前**的值，照它显示永远慢一步（实测回车后选中已到第二个、载荷仍是 1）。改成数 `.textLayer .highlight`、认带 `selected` 类的那个，并用 `MutationObserver` 去抖刷新 —— 固定延时会抢在"清空高亮"之前跑出旧数字 |
| 5 | 反色后的页底 | 白底反色得到的是纯黑，比 `--bg0` 深一截。合成时补一步 `globalCompositeOperation = 'lighten'` + 填板色：黑底被抬到板色，正文比板色亮所以原样保留 |
| 6 | 主题色的单一来源 | 新增 `src/lib/chalk-palette.ts`，由 `typst-compile.ts`（拼 wrapper）与 `DocumentViewer`（抬页底）共用。CSS 那份仍在 `+layout.svelte`，两处仍需同步 |
| 7 | 顺带修掉的既有问题 | ① `+page.svelte` 的全局 keydown 不忽略输入框（打字会搅乱文件树，见正文）；② `FileTree.svelte` 的 `bind:this={rowElements[i]}` 绑到非响应式属性，Svelte 5 每次加载刷 8 条警告 —— 改成 `$state` 数组 |
| 8 | 依赖 | `package.json` 里写着 `vitest` 但 `node_modules` 里**没装**，`npm run test` 原本跑不起来；已 `npm install` 补上，同时装 `pdfjs-dist@6.3.289` |
| 9 | 验证手段 | 除 curl 外，用 `chromium --headless=new --remote-debugging-port` + CDP 脚本做了真实浏览器验证：截图、点文件树切文档、驱动搜索与缩放、收集未捕获异常。设计的验证清单里"必须真机/模拟器验"的项目，本次是用无头 Chromium 验的 |
| 10 | **必须用 legacy 构建** | 第一版用了 `pdfjs-dist/build/pdf.mjs`（modern），在你的浏览器里报 `文档加载失败：this[#listeners].getOrInsertComputed is not a function` —— modern 构建直接用 `Map.prototype.getOrInsertComputed` 这类新 API，没有它整个文档打不开。改成 `legacy/build/pdf.mjs` + `legacy/build/pdf.worker.min.mjs`：里面带 core-js 补丁（含特性探测），代价约 +60KB 主包 / +50KB worker。我的无头 Chromium 是 152（已支持该 API）所以第一轮没暴露 —— 教训是**验证环境的浏览器版本也是变量**，复现办法见下 |
| 11 | 工具栏对三种格式一视同仁 | 工具栏原先长在 `DocumentViewer` 里，markdown 没有。改成三格式共用同一个 `DocumentToolbar`：markdown 走新增的 `MarkdownView.svelte`（自己实现 DOM 内查找 + 调字号），typst/pdf 仍走 `DocumentViewer`。markdown 没有「页」，所以页码位不渲染；`⤢` 换成 `↺`（前者读起来像「放大」），按钮含义随格式变 |
| 12 | 缩放状态的生命周期 | 新增 `src/lib/preview-zoom.ts`：markdown 字号与 pdf/typst 缩放都存模块作用域，**一次页面访问内**换文件、切格式都保留，刷新或关标签页即复位。纯内存，不落 localStorage、不上服务端 —— 与文件树展开状态同口径。此前 pdf 那侧每次挂载都把 `currentScaleValue` 设回 `page-width`，换文件即丢，属于不一致 |

验证结果（真实浏览器）：

- typst 路径：暗底粉笔页，两栏 grid、表格、链接、彩色分隔线、图片全部正确
- pdf 路径：白底被转成板色页底，**照片保持原色**（图像豁免生效）
- 状态栏：`cv.pdf` 显示 `23.4K`（真实字节），`cv.typ` 显示 `1.3K`
- 搜索：`the` → `1 / 2` → 回车 `2 / 2` → 再回车回绕 `1 / 2` → Shift+回车反向；搜不存在的词 → `0 / 0` 且高亮为 0
- 缩放：页宽 936 → 1120（放大）→ 937（适应宽度）
- 路由：`/raw/cv.pdf` 200 + 正确头；`/typst/cv.typ` 200 + `%PDF-`；ETag 命中 304；`/raw/readme.md`、`/typst/cv.pdf`、`/raw/missing.pdf`、`--path-as-is` 穿越一律 404；编译失败 422 + 一行式诊断且不含 wrapper 文件名
- 控制台干净：无未捕获异常、无警告

**仍未验证的**：真机移动端（无头 Chromium 不等于 iOS Safari / Android Chrome）、`ctx.filter` 不可用时的 CSS 回退分支（Safari 路径）、多页文档的滚动与预取行为（样例只有 1 页）、`Ctrl+F` 在真实按键下的表现。

**旧浏览器的复现办法**（第 10 条的验证手段，将来改 pdf.js 版本时要重跑）：

```js
// CDP: Page.addScriptToEvaluateOnNewDocument，必须在应用脚本之前执行
delete Map.prototype.getOrInsertComputed;
delete Map.prototype.getOrInsert;
delete WeakMap.prototype.getOrInsertComputed;
delete WeakMap.prototype.getOrInsert;
```

删完再加载页面并打开文档：modern 构建会报 `getOrInsertComputed is not a function`，legacy 构建能靠 core-js 补丁自愈（实测 `typeof Map.prototype.getOrInsertComputed` 会从 `undefined` 变回 `function`，画布正常渲染）。

## 风险

- **pdf.js 约 2.2 MB**（主包 458 KB + worker 1.26 MB + viewer 层 320 KB + CSS 163 KB）。已用动态 import 懒加载，markdown-only 访客不受影响；首次点开 typst/pdf 会有一次可感知的下载
- **`static/pdfjs/` 会让仓库变大**（cMaps + 标准字体约 2 MB 级）。访客只会按需拉取命中的那一个 `.bcmap` / 字体文件，不增加页面首屏负担，但仓库确实变大。若不接受，替代方案是加一条从 `node_modules` 流式读的只读路由 —— 复杂度更高，本次不做
- **照片能豁免，矢量色块不能**：pdf 里的图像对象按 `getOperatorList()` 定位后跳过反色；但矢量色块、图表线条、表格边框与文字同为矢量算子、无法区分，**仍会被反色**（见「视觉规格」）。旋转 / 裁剪 / 带遮罩的图像按包围盒处理，边界可能略有出入；算子列表解析异常时回退整页反色
- **主题色两处重复**：`+layout.svelte` 的 CSS 变量与 `typst-compile.ts` 的常量。服务端读不到 CSS，这是有意的取舍；改主题色要同步两处
- **Ctrl+F 覆盖不到缓冲外的页**（约 10 页）。这是 pdf.js 写死的缓冲策略、没有公开选项；搜索栏补上完整覆盖。若将来嫌这个边界碍事，只能改常量或自己预渲染 —— 都不做
- **全站搜索没有做**（决策 12）。它需要索引、结果列表、与「只靠文件树导航」的模型对接，是独立功能
- **typst 编译需要写 `content/`**：wrapper 必须与文档同目录才能正确解析相对 include。编译中途进程被杀可能留下 `.preview-*.typ`；因为树跳过点号文件，对访客不可见，但会留在磁盘上
- **首次编译可能要联网**：文档若用 `@preview` 包，typst 需下载；失败会走 422 诊断面板，不会白屏
- **字体**：typst 用系统字体，服务端缺字体会**静默 fallback**，预览与作者本机不一致
- **编译超时 10s**：超时按失败处理并给出诊断。极重的文档（大量图片、复杂排版）可能触顶
- **pdf.js 只能客户端初始化**：模块顶层不碰 pdf.js，必须动态 import，否则 SSR 阶段会炸
