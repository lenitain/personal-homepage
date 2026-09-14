/**
 * typst 摆放原语的静态检查 —— 把「静默吞内容」变成「编译不过」。
 *
 * typst 的 HTML 导出只保留**结构**，丢弃**二维摆放**。危险的不是丢摆放本身，
 * 而是失败模式：`#grid` / `#place` 这类**容器**被丢弃时，会连坐整棵子树 ——
 * 里面的文字、链接、图片一起消失，而 typst 只给一条通用的
 * `html export is under active development and incomplete`，退出码 0。
 *
 * 也就是说：作者把内容包进一个 `#grid` 里想要两栏，结果正文从页面上**消失**，
 * 没有任何一处报错。这是这个管线唯一会静默吃掉内容的路径，所以值得单独拦。
 *
 * 这个模块只做「源码里有没有出现这些调用」的判定，是纯函数，判定规则可以被单测
 * 钉住；真正的全量扫描在 typst-primitives.test.ts 里对 content/ 跑一遍。
 */

/** 在 HTML 导出下会被丢弃的 typst 函数。丢弃的是摆放，容器被丢弃时会连坐内容。 */
export const DROPPED_IN_HTML_EXPORT = [
	'grid',
	'place',
	'columns',
	'rect',
	'line',
	'stack',
	'align',
	'v'
] as const;

export type DroppedPrimitive = (typeof DROPPED_IN_HTML_EXPORT)[number];

export interface PrimitiveHit {
	/** 命中的原语名。 */
	primitive: DroppedPrimitive;
	/** 1 起的行号，直接可用于报错。 */
	line: number;
	/** 该行原文，裁掉尾部空白，报错时贴出来。 */
	text: string;
}

/**
 * markdown 写法在 typst 里的下场。
 *
 * 这几条不是「风格问题」，是**静默失效**：typost 不认这些语法，但也不会报错，
 * 于是它们会以字面字符的形式出现在页面上，或者让一行悄悄少一截。
 *
 * 加这个检查是因为这几条被反复踩到 —— 人（和我）写 markdown 的手感太强，
 * 而 typst 的 markup 语法跟它长得像、规则却不同，正是最容易出错的地方。
 */
export const MARKDOWN_ISMS = {
	'**': 'typst 的粗体是单星号 `*粗体*`，双星号会报 "no text within stars"',
	'##': 'typst 的标题是等号 `=`，`#` 是代码入口，写 `##` 会直接编译失败',
	'>': 'typst 的引用块是 `#quote(block: true)[...]`，`>` 会原样渲染成字面字符',
	'|': 'typst 没有 markdown 表格语法，表格要写 `#table(...)`，`|` 会原样渲染',
	'[]()': 'typst 的链接是 `#link("url")[文字]`，markdown 的 `[文字](url)` 会整段原样渲染'
} as const;

export type MarkdownIsm = keyof typeof MARKDOWN_ISMS;

export interface MarkdownIsmHit {
	kind: MarkdownIsm;
	line: number;
	text: string;
	/** 人话解释这条为什么不行、该怎么写。 */
	reason: string;
}

/**
 * 扫一份 typst 源码，返回所有会破坏 HTML 导出的摆放原语调用。
 *
 * 判定的是**调用**而不是**名字**：`#grid(` 与 `#grid[` 算命中，正文里提到
 * "grid" 这个单词、或者注释里写 `#grid` 不算。所以只在 `#` 或 `.` 之后、
 * 紧跟可选空白与调用括号时才认。
 *
 * 注释与字符串要跳过 —— 否则「本文用到了 #grid 因此…」这句教学说明会被自己拦下来，
 * 而课件的正文里恰恰会反复提到这些名字。
 */
export function findDroppedPrimitives(source: string): PrimitiveHit[] {
	const hits: PrimitiveHit[] = [];
	const lines = source.split('\n');

	let inBlockComment = false;

	for (let index = 0; index < lines.length; index++) {
		const line = lines[index];
		const scanned = stripCommentsAndStrings(line, inBlockComment);
		inBlockComment = scanned.inBlockComment;

		for (const primitive of DROPPED_IN_HTML_EXPORT) {
			if (callsPrimitive(scanned.code, primitive)) {
				hits.push({ primitive, line: index + 1, text: line.trimEnd() });
			}
		}
	}

	return hits;
}

/**
 * 把一行里的注释与字符串字面量抹成空白，只留代码部分。
 *
 * 只处理**行内**语法：行注释、块注释（跨行状态由调用方传递）、双引号字符串、
 * 反引号原始文本。这四种里都可能出现这些名字，一并抹掉。
 */
function stripCommentsAndStrings(
	line: string,
	inBlockComment: boolean
): { code: string; inBlockComment: boolean } {
	let out = '';
	let index = 0;

	while (index < line.length) {
		if (inBlockComment) {
			const end = line.indexOf('*/', index);
			if (end === -1) return { code: out, inBlockComment: true };
			index = end + 2;
			inBlockComment = false;
			continue;
		}

		const rest = line.slice(index);

		if (rest.startsWith('//')) break; // 行注释，本行到此为止
		if (rest.startsWith('/*')) {
			inBlockComment = true;
			index += 2;
			continue;
		}
		if (line[index] === '"') {
			const end = findStringEnd(line, index + 1);
			index = end === -1 ? line.length : end + 1;
			out += ' ';
			continue;
		}
		if (line[index] === '`') {
			const end = line.indexOf('`', index + 1);
			index = end === -1 ? line.length : end + 1;
			out += ' ';
			continue;
		}

		out += line[index];
		index++;
	}

	return { code: out, inBlockComment };
}

/** 找字符串的收尾引号，跳过 `\"` 转义。找不到返回 -1。 */
function findStringEnd(line: string, from: number): number {
	for (let index = from; index < line.length; index++) {
		if (line[index] === '\\') {
			index++;
			continue;
		}
		if (line[index] === '"') return index;
	}
	return -1;
}

/**
 * 这段代码里有没有 `#grid(` / `.grid(` 这样的调用。
 *
 * 要求前面是 `#` 或 `.`：前者是 typst 的代码入口，后者是方法调用链
 * （`foo.grid(...)`，同样会被丢弃）。这样正文里的裸单词 "grid" 不会误报。
 */
function callsPrimitive(code: string, primitive: string): boolean {
	const pattern = new RegExp(`[#.]\\s*${primitive}\\s*[(\\[]`);
	return pattern.test(code);
}

/**
 * 扫一份 typst 源码，返回所有**会静默失效的 markdown 写法**。
 *
 * 只在代码围栏之外判定：代码块里的 `>`、`|`、`##` 是终端输出和 diff，
 * 原样保留才是对的（课件的实验记录里全是这些）。注释里的也不算 ——
 * 注释里写 `**结构 vs 视觉**` 是给人看的，typst 根本不解析。
 *
 * 判定刻意做得窄 —— 只认「行首」的那些：
 *
 * - `**` 出现在任何位置都算（typst 里它没有合法用途）
 * - `##` 只认行首（正文里提到 `##` 是正常的，比如这句注释）
 * - `>` 只认行首（`->`、`>=` 这类符号不该误报）
 * - `|` 只认行首且行内还有第二个 `|`（markdown 表格的形状）
 * - `[文字](url)` 认整条链接，且括号里要含 `:` 或 `/`（见 `MARKDOWN_LINK`）
 */
export function findMarkdownIsms(source: string): MarkdownIsmHit[] {
	const hits: MarkdownIsmHit[] = [];
	const lines = source.split('\n');

	let inFence = false;
	let inBlockComment = false;

	for (let index = 0; index < lines.length; index++) {
		const raw = lines[index];

		if (raw.trimStart().startsWith('```')) {
			inFence = !inFence;
			continue;
		}
		if (inFence) continue;

		// 注释先抹掉 —— 注释里出现这些符号是正常的，而且它们不会被渲染
		const scanned = stripCommentsAndStrings(raw, inBlockComment);
		inBlockComment = scanned.inBlockComment;
		const line = scanned.code;

		const text = raw.trimEnd();
		const push = (kind: MarkdownIsm) =>
			hits.push({ kind, line: index + 1, text, reason: MARKDOWN_ISMS[kind] });

		if (line.includes('**')) push('**');

		const trimmed = line.trimStart();
		if (/^#{2,}/.test(trimmed)) push('##');
		if (/^>\s/.test(trimmed)) push('>');
		if (/^\|.*\|/.test(trimmed)) push('|');

		// 链接要在**抹掉行内代码之前**的版本上判：markdown 链接的文字几乎总带反引号
		// （`` [`qb-open`](url) ``），而 `stripCommentsAndStrings` 会把反引号对之间的
		// 内容整段抹掉 —— 用它判就永远命中不了。注释仍然要排除。
		if (findMarkdownLinks(raw).length > 0) push('[]()');
	}

	return hits;
}

/**
 * 一份 typst 源码里所有**写成 markdown 的链接**。
 *
 * 只认「行注释之外」的部分，而且刻意做成纯函数：判定规则能被单测钉住，
 * 而不是埋在 `findMarkdownIsms` 的循环里。
 *
 * ## 为什么先做占位替换
 *
 * 「行注释从哪儿开始」在 typst 里不能靠找 `//` 来判断 —— URL 里就有（`https://`）。
 * 但只找 `://` 又会漏掉 `#link("//example.com")` 这种。所以先把**反引号里的
 * 行内代码**和**双引号里的字符串**换成占位符（注释不会出现在这两者里面），
 * 这时剩下的 `//` 就只可能是注释了。
 */
export function findMarkdownLinks(source: string): string[] {
	return source
		.split('\n')
		.flatMap((line) => stripComment(line).match(MARKDOWN_LINK) ?? []);
}

/**
 * 去掉行注释。
 *
 * 判定注释从哪儿开始不能靠找 `//` —— URL 里就有（`https://`），
 * 一刀切下去剩下的半截链接再也匹配不上。取「前面是空白或行首的那个 `//`」：
 * 这正是 typst 注释的写法（`// 说明`），而 URL 里的 `//` 前面是 `:`。
 */
function stripComment(line: string): string {
	const comment = /(^|\s)\/\//.exec(line);
	if (!comment) return line;
	// 保留那个分隔用的空白之前的部分
	return line.slice(0, comment.index + comment[1].length);
}

const MARKDOWN_LINK = /\[[^\[\]]+\]\([^()\s]*(?::|\/)[^()\s]*\)/g;
