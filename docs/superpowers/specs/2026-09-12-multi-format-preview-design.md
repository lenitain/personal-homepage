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
3. 两类排版文档的文字**可选中**（原话：「typst 不可选中完全不可接受」）
4. **移动端可用**（原话：「移动端渲染不了 pdf 吗，肯定有方法的」）
5. 两类排版文档统一到黑板的粉笔风格，且**不做风格开关，永远开着**

## 已敲定的决策

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | typst 预览的含义 | 编译后的排版结果 |
| 2 | 载体收敛 | 全站只有两种载体：**Markdown** 与 **PDF**。typst 编译成 PDF 后与 pdf 走同一条渲染路径 |
| 3 | 为什么不用 SVG | `--format svg` 的字是**字形轮廓**，实测整页 0 个 `<text>` 元素，文字不可选中（详见「实测记录」A） |
| 4 | 为什么不用 typst 的 HTML 导出 | 实测 `#grid` / `#place` / `#rect` 被**静默丢弃**且 exit 0，用 `#grid` 排两栏的真实 CV 会渲染成空白（详见「实测记录」B） |
| 5 | 为什么不用原生 iframe 嵌 PDF | 移动端不可用：Android 触发下载、iOS 只渲染第一页（详见「实测记录」C） |
| 6 | 渲染器 | **pdf.js**（`pdfjs-dist`）。它的文字层是官方一等 API，选中/搜索对 typst 与 pdf 一视同仁 |
| 7 | 两类文档的风格 | typst：**编译期**注入主题（页底、正文、链接、代码色）；现成 pdf：**canvas 上的 CSS filter** 整页处理。两者都常开，**不做开关** |
| 8 | 树的收录范围 | 只收 `.md` / `.typ` / `.pdf`；**点号开头的文件与目录一律跳过** |
| 9 | 站内搜索框 | **不做**。文字层保证可选中；原生 viewer 那个搜索 UI 随之失去，这一条明确接受 |
| 10 | 缩放控件 | **不做**缩放按钮。默认 fit-width 随容器自适应，要放大用浏览器自身的缩放/捏合 |

## 不做什么

- 图片 / txt / 其他类型的预览（树里也不显示）
- typst 源码视图（决策 1 已排除）
- 站内搜索框（决策 9）
- **PDF 的逐对象风格化** —— 做不到：PDF 里公式、图片、色块、表格边框是矢量路径或位图，没有可提取的排版对象；文字层只提供「文字片段 + 坐标」，没有「这是标题」这种语义。能做的是整页级处理（决策 7）
- 自建 viewer 的工具栏（打印 / 下载 / 搜索 / 缩略图）

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

[How to Embed PDF in HTML](https://www.dynamsoft.com/codepool/how-to-embed-pdf-in-html.html) 的对比结论：`<iframe>` 在移动端 **Android 触发下载、iOS 只渲染第一页**，并建议用 JS viewer 换取一致的跨端行为。与 pdf.js 的定位一致。

### E. pdfjs-dist 的可发货面

`pdfjs-dist@6.3.289`，包内**没有** `exports` 映射，深路径导入合法：

| 路径 | 体积 | 用途 |
| --- | --- | --- |
| `build/pdf.min.mjs` | 458 KB | 主入口，导出 `getDocument` / `TextLayer` / `AnnotationLayer` / `GlobalWorkerOptions` / `setLayerDimensions` |
| `build/pdf.worker.min.mjs` | 1.26 MB | worker，用 `?url` 导入后赋给 `GlobalWorkerOptions.workerSrc` |
| `web/pdf_viewer.css` | 163 KB | `textLayer` / `annotationLayer` 的定位规则 |

主入口与 worker 合计约 1.7 MB，**动态 import 懒加载**：只看 markdown 的访客不付这笔钱，首次点开 typst/pdf 才下载。

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
3. 扩展名不在 `.pdf` 白名单（该函数只服务 `/raw`；`/typst` 用另一份 `.typ` 白名单，同一实现参数化）
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

流程：

1. `fetch(url)` → 不 ok 就按 content-type 解析 JSON 诊断，渲染报错面板（`.typ` 的编译错误走这里）；ok 就 `arrayBuffer()`
2. 动态 `import('pdfjs-dist')`，把 `?url` 导入的 worker 赋给 `GlobalWorkerOptions.workerSrc`（**只能客户端做**，模块顶层不碰 pdf.js）
3. `getDocument({ data })` → `numPages`
4. 每页一个占位容器，`IntersectionObserver` 只渲染可见页（±1 页），避免长文档一次性铺开
5. 每页渲染三层：`<canvas>` + 文字层容器（`class="textLayer"`）+ `AnnotationLayer`（让链接可点）
6. 用 pdf.js 导出的 `setLayerDimensions()` 设置层尺寸 —— v4+ 处理 `--scale-factor` 与旋转的正确做法，手写会错位

三态：**编译中 / 报错面板 / 页面列表**。页码指示（`3 / 8`）放 viewer 右下角一个轻量浮标，不做工具栏。

缩放：默认 fit-width，`ResizeObserver` 跟随容器宽度重算；**不提供缩放按钮**（决策 10）。

**文字层 CSS 直接 `import 'pdfjs-dist/web/pdf_viewer.css'`**，不自己抄：文字层的定位规则随版本变过（`--scale-factor`、`transform`、`setLayerDimensions` 配套），抄一份迟早对不上；该文件大部分规则挂在 `.pdfViewer` 类下不会外溢到站点，且它随文档 chunk 懒加载。

`tone` 决定 canvas 上套哪一组 filter（见「视觉规格」）。

## 视觉规格

### 滤镜落位（`+page.svelte` 改）

现在 `filter: url(#chalk-writing)` 套在 `.content-pane` **整栏**上（`+page.svelte:209-213`）。改成：

| 目标 | 滤镜 |
| --- | --- |
| markdown `article` | `url(#chalk-writing)`（不变） |
| typst 的 canvas | `url(#chalk-writing)`（文档在编译期已经是暗底粉笔色，只补颗粒） |
| pdf 的 canvas | `invert(1) hue-rotate(180deg) sepia(0.3) saturate(1.3) brightness(1.05) url(#chalk-writing)`（起步参数，实现时目视调） |
| 文字层 | **不套** —— 它本身透明，套了只会让选中高亮变糊 |
| 整个 `.content-pane` | **不套** |

两条理由：SVG turbulence 滤镜在大滚动区上会反复重栅格化，多页文档会掉帧 —— 改成**按页**套；而套在 iframe 上只会把原生 viewer 的工具栏一起糊掉、底色却还是白的（这是上一版决定用 iframe 时的遗留问题，现在 iframe 没了，规则一并收紧）。

### 现成 pdf 的整页风格化：能做到什么程度

实测（ImageMagick 近似 CSS 的 `invert(1) hue-rotate(180deg)`）：白底页 mean=0.998 → 处理后 0.0035，暗底亮字成立，粉笔颗粒可再叠。

**验收标准**（不是像素级匹配，是观感）：页底接近 `--bg0`、正文接近 `--fg`、看不出明显负片感。滤镜参数在实现时对着真实 pdf 调。

**明确的代价**（写进「风险」，不假装解决）：整页滤镜会把 pdf 里的**图片/照片一起反成负片**；彩色图表会出现反色失真（`hue-rotate` 只能拉回色相，拉不回明度关系）。这是「不做逐对象风格化」的必然结果。

### 文字选中

pdf.js 的文字层是真实 DOM 文字，选中由它保证。选中高亮的配色跟着站点的 `::selection`（`--bg3` 底 / `--fg` 字）走，落在暗底页面上可见；若实测对比不足，在 viewer 内覆盖 `.textLayer ::selection` 单独加一档对比。

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
| `src/lib/components/DocumentViewer.svelte` | 新增。pdf.js viewer，两类文档共用 |
| `src/lib/components/ContentPane.svelte` | 改。按 kind 分派；markdown 样式与滤镜落位 |
| `src/lib/components/Status.svelte` | 改。`size` 改用 `entry.size`，B/K/M 正常进位 |
| `src/routes/+page.svelte` | 改。滤镜从整栏下沉到 article |
| `package.json` | 加 `pdfjs-dist` 依赖 |
| `content/cv.typ` + `content/cv.pdf` | 新增。**占位样例**，跑通链路用，之后换成真文件 |

`package.json` 的 `pdfjs-dist` 放 `dependencies`（运行时要用），不是 devDependencies。

### 状态栏的顺带修复

`Status.svelte:18` 现在用 `entry.content?.length` 当字节数 —— 对 markdown 是**字符数**、对二进制是错的。改用 `entry.size`。`meta` 那格 `{ext} file` 保持原样（`typ file` / `pdf file` 读得通）。

## 测试

`vitest` 只跑 `src/**/*.test.ts` 的纯逻辑（`vite.config.ts` 既有约定），组件仍靠手点。

- `preview-kind.test.ts` —— 三种扩展名、大小写、无扩展名、`.mdx` / `.markdown` 这类近似值必须返回 null
- `content-path.test.ts` —— `..%2f` 之类编码后穿越、`a/../b`、绝对路径、NUL、`.png` 非白名单、正常嵌套路径
- `content-tree.test.ts` —— 三类都进树、`.png` 不进、点号文件/目录不进、目录 size 不设、markdown 仍内联 content、typst/pdf 的 content 为 undefined
- `typst-compile.test.ts` —— 临时 fixture 真调 typst，只断言这些能稳定断言的事：编译成功返回以 `%PDF` 开头的非空 Buffer、语法错误返回诊断且**不含 wrapper 的临时文件名**、wrapper 文件编译后被删除（fixture 目录里不再有 `.preview-*.typ`）、第二次调用命中缓存（不重新 spawn：拿编译产物的对象引用或 `mtimeMs` 判定）

整组用 `describe.skipIf(!hasTypst)` 包住（`hasTypst` 用 `spawnSync('typst', ['--version'])` 判定），换一台没装 typst 的机器不至于整片挂掉。

## 验证

1. `npm run check`（svelte-check）零错误
2. `npm run test`
3. 起 dev server 手点：

- [ ] markdown：点开 `readme.md`，观感与改动前**逐像素一致**（滤镜下沉后不能变糊或变清）
- [ ] typst：点开 `content/cv.typ`，出现暗底粉笔页；内容与 `content/cv.pdf` 的排版一致（两栏、表格、彩色分隔线都在）
- [ ] typst：文字**能拖选**，选中高亮与文字重合（错位就说明 `textLayer` 的 scale/尺寸没接好）
- [ ] typst：多页文档滚到底，页数与内容正确；滚动时只渲染可见页（DevTools 里 canvas 数量不随页数线性增长）
- [ ] pdf：点开 `content/cv.pdf`，白底被整页转成暗底亮字，观感接近 typst 那一版
- [ ] pdf：文字能拖选；文档里的链接可点
- [ ] **编译错误**：故意在 `cv.typ` 里写 `#let x =`，右栏出现诊断面板且只报真实文件名与行号，不出现 `.preview-xxxx.typ`
- [ ] 修好后重新打开能恢复，不需要重启 dev server（缓存按 mtime 失效）
- [ ] 改一个被 `#include` 的片段，重新打开该文档，预览跟着变（deps 缓存失效生效）
- [ ] `curl --path-as-is -i 'localhost:5173/raw/../../etc/passwd'` 与编码变体一律 404，不返回文件（**必须带 `--path-as-is`**，否则 curl 自己就把 `..` 归一化了，测的是空气）
- [ ] `curl -i localhost:5173/raw/readme.md` → 404（白名单只有 pdf）
- [ ] 状态栏：pdf 显示真实字节数（不再是字符数）
- [ ] 窄视口（≤640px）：pdf/typst 页面 fit-width、不横向溢出；树浮层行为不变
- [ ] 手机（或 DevTools 移动模拟）上打开 pdf：能渲染且能选中 —— 这条是本次改动的主要动机，必须真机或模拟器验
- [ ] 只看 markdown 时，Network 面板里**没有** pdf.js 的 chunk（懒加载生效）

## 风险

- **pdf.js 约 1.7 MB**（主包 458 KB + worker 1.26 MB + CSS 163 KB）。已用动态 import 懒加载，markdown-only 访客不受影响；首次点开 typst/pdf 会有一次可感知的下载
- **整页滤镜会反色 pdf 内的图片/照片**，彩色图表也会失真（见「视觉规格」）。这是不做逐对象风格化的必然结果，用户已知悉并选择「统一风格化、去掉开关」
- **主题色两处重复**：`+layout.svelte` 的 CSS 变量与 `typst-compile.ts` 的常量。服务端读不到 CSS，这是有意的取舍；改主题色要同步两处
- **搜索框没有了**：原生 viewer 的搜索 UI 随之失去（决策 9）。文字层保证可选中；网页版 `Ctrl+F` 对文字层能否高亮未经验证，**不写进承诺**
- **typst 编译需要写 `content/`**：wrapper 必须与文档同目录才能正确解析相对 include。编译中途进程被杀可能留下 `.preview-*.typ`；因为树跳过点号文件，对访客不可见，但会留在磁盘上
- **首次编译可能要联网**：文档若用 `@preview` 包，typst 需下载；失败会走 422 诊断面板，不会白屏
- **字体**：typst 用系统字体，服务端缺字体会**静默 fallback**，预览与作者本机不一致
- **编译超时 10s**：超时按失败处理并给出诊断。极重的文档（大量图片、复杂排版）可能触顶
- **pdf.js 只能客户端初始化**：模块顶层不碰 pdf.js，必须动态 import，否则 SSR 阶段会炸
