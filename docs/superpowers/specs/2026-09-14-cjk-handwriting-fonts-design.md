# 中文手写体：给粉笔风格补上中文，并留出降级链

> 英文早就是手写体（Kalam），中文却一直掉在系统字体上 —— 于是同一行里「手写 + 印刷」
> 混着，粉笔滤镜反而把中文糊成了一种很像 Noto 的东西。这份规格解决这一件事：
> **中文也走手写体，且缺字时逐级降级。**

## 背景

现状的字体链是 `'Kalam', 'Patrick Hand', 'Yusei Magic', cursive`，硬编码在四个地方
（`+layout.svelte`、`+page.svelte`、`DocumentView.svelte` 两处）。

它看起来「有三个字体」，但逐个量过之后，中文的实际处境是这样的：

| 事实 | 实测值 |
| --- | --- |
| 站内用到的汉字（去重） | **969** |
| `Yusei Magic` 覆盖其中 | **715 个** —— 但它是**日文字体**，这些字按日文字形渲染 |
| 剩下 254 个 | 掉到系统 `Noto Sans CJK SC` |
| 站内日文假名内容 | **0** |
| `Yusei Magic` 为本站下载的字体文件 | **1171 KB** |

也就是说中文今天既不是「手写」也不是「统一的印刷体」，而是**日文字形的 Yusei Magic 与
Noto 两掺**。用户看到的那部分 Noto，其实只是没被 Yusei Magic 命中的那 254 个字。

## 目标

1. 中文和英文一样，是手写粉笔字
2. 中文字体缺字、或 CDN 不可达时，有明确的降级次序，而不是直接掉到系统默认
3. 字体链只有一处定义
4. 不显著增加页面体积

## 已敲定的决策

| # | 决策 | 结论 |
| --- | --- | --- |
| A | 字体链 | `'Kalam', 'Patrick Hand', 'ZCOOL KuaiLe', 'LXGW WenKai', 'Ma Shan Zheng', cursive, sans-serif` |
| B | 谁管中文 | **ZCOOL KuaiLe（站酷快乐体）**。手绘马克笔气质，和 Kalam 的随意感最接近 |
| C | 降级次序 | 逐字降级，浏览器原生行为：A 缺字/加载失败 → LXGW WenKai → Ma Shan Zheng → generic |
| D | 尾部 | **C 之后不接任何命名字体**，只留 `cursive, sans-serif`（用户明确要求「只要 abc」） |
| E | `Yusei Magic` | **从链条中删除**。站内无日文；它今天贡献的是日文字形 + 1171 KB |
| F | 载入方式 | **CDN 分片**：沿用 jsDelivr + fontsource，与现有三个字体一致。不做自托管子集 |
| G | 定义处 | 收敛成 `+layout.svelte` 里 `:global(body)` 上的 `--font-chalk`，四处硬编码改为引用它 |
| H | 粗体与行高 | **先不动**。今天 Kalam 也只有 400 一个字重，合成粗体是既有行为；中文是否发糊留到视觉验收再定 |

## 实测依据

### 一、为什么用 CDN 分片而不是自托管子集

Google 那套中文字体在 fontsource / jsDelivr 上已经被按 `unicode-range` 切成 90 多个分片，
浏览器**只下当前页面真正用到的字所在的那几片**。按站内 969 个字算：

| 字体 | 需要的分片 | 体积 |
| --- | --- | --- |
| ZCOOL KuaiLe | 21 / 93 | **448 KB** |
| LXGW WenKai | 21 / 97 | 1143 KB |
| Ma Shan Zheng | 21 / 92 | 1607 KB |

自托管子集（`pyftsubset` 按 969 个字裁一个 woff2）确实更快，但代价是**多一个构建步骤，
且新写的正文一旦出现没进子集的字就会缺字**。对一个持续在写内容的主页来说，这个长期
负债比那几百 KB 更贵。所以选分片。

### 二、B 和 C 在正常情况下的下载量是 0

逐个字符核对过：ZCOOL KuaiLe 对站内 969 个字的覆盖是**满的**，包括 `——`「」《》【】、
。、？！：；（）这些标点（`U+2014` / `U+300C-300D` / `U+3001-3002` / `U+FF01-FF5D` 全部命中）。
它「覆盖」不等于它「接管」—— 链条上排在它前面的字体先赢，见下一节。

于是 B、C 只在两种情况下才会真正用到：**A 缺字**（以后内容里出现 ZCOOL 未收录的字），
或者 **A 加载失败**。浏览器不会为用不到的字体下载字体文件 —— 这让「多加两层降级」
的实际代价只剩 CSS：

| | 原始 | gzip |
| --- | --- | --- |
| zcool-kuaile index.css | 100753 B | 31185 B |
| lxgwwenkai-regular.css | 105359 B | 31399 B |
| ma-shan-zheng index.css | 100181 B | 30867 B |
| **三个 CJK CSS 合计** | | **~93 KB** |

### 三、标点：`——` 与弯引号仍然走 Kalam

`Kalam` 的 latin 面 unicode-range 含 `U+2000-206F`，也就是 `—`（U+2014）、`""`、`…`
都在里面。这些标点走英文手写体是**观感正确**的，不需要干预。

## 体量对比

| | 现在 | 改后 |
| --- | --- | --- |
| 字体 CSS（gzip） | 31 KB | ~94 KB |
| 字体文件（首访） | Yusei Magic 1171 KB | ZCOOL 448 KB，**B/C 为 0** |
| **合计** | **~1.2 MB** | **~0.55 MB** |

净减约 650 KB，同时中文从「日文字形 + Noto」变成手写体。

## 不做什么

- **不动英文**：Kalam 与 Patrick Hand 原样保留
- **不做自托管子集**：理由见上
- **不引入中文专属字号 / 行高体系**：先让字体到位；视觉验收时若行高确实变紧再单独处理
- **不预先关闭合成粗体**：中文笔画密，合成加粗在滤镜下可能发糊，但这需要先看到实际效果再判断。真糊了再加 `font-synthesis-weight: none`，让强调只靠颜色（`strong` 本来就是橙色）
- **不加 `preconnect`**：现有三条 `<link>` 已经指向同一个源，收益边际

## 改动清单

### `src/app.html`

加三条：

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource/zcool-kuaile@5/index.css" />
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/lxgw-wenkai-webfont@1.7.0/lxgwwenkai-regular.css" />
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource/ma-shan-zheng@5/index.css" />
```

删一条：`@fontsource/yusei-magic@5/index.css`。

### `src/routes/+layout.svelte`

在 `:global(body)` 里定义唯一真源：

```css
--font-chalk: 'Kalam', 'Patrick Hand', 'ZCOOL KuaiLe', 'LXGW WenKai', 'Ma Shan Zheng', cursive, sans-serif;
font-family: var(--font-chalk);
```

### 其余三处

`+page.svelte`、`DocumentView.svelte`（`.failure pre` 与 `article code`）改为
`font-family: var(--font-chalk)`。

### 回归保护

新增一个测试，扫 `src/` 下的 `.svelte` 文件，断言：除 `+layout.svelte` 外没有任何地方
再硬编码 `Kalam` 字体栈。这条约束是本次设计的 G 决策，不写测试就会在下次改样式时退化。

## 验证

1. `pnpm test` 与 `pnpm check` 全绿
2. 用 headless chromium 打开真实课件页（`content/hacks/resident-browser/index.typ`），
   截改前 / 改后对照图，确认中文笔画形态确实变了
3. 浏览器 Network：确认只请求了 ZCOOL 的分片，**B/C 的 woff2 一次都没被请求**
4. 核对 969 个汉字 + 全角标点无豆腐块
5. 窄视口（≤640px）与演示模式各看一眼（这两处字号会变）

## 风险

| 风险 | 说明 | 处理 |
| --- | --- | --- |
| 合成粗体发糊 | ZCOOL 只有一个字重，`<strong>` 走浏览器合成加粗；中文笔画密，粉笔滤镜下可能糊成一团 | 视觉验收时专门看一眼；糊了就加 `font-synthesis-weight: none` |
| 字形占位不同 | 中文手写体在 em 框里通常比 Kalam 满，行高观感可能变紧 | 验收时一并看，必要时只调正文行高 |
| CDN 不可达 | A/B/C 全部拿不到时会退到 `cursive, sans-serif`，中文回到系统默认 | **已接受**（用户明确选择尾部不接命名字体） |
| 字体替换时的闪动 | `font-display: swap` 会先用降级字体渲染，字体到位后再替换，出现一次字形跳动 | 已接受：与现有三个字体行为一致 |
