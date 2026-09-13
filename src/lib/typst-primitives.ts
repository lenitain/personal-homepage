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
