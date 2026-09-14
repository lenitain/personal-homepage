import { describe, expect, test } from 'vitest';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { CONTENT_DIR } from './content-dir.server';
import { findDroppedPrimitives, findMarkdownIsms } from './typst-primitives';

describe('findDroppedPrimitives', () => {
	test('命中 # 开头的调用', () => {
		expect(findDroppedPrimitives('#grid(columns: (1fr, 1fr))[甲乙]')).toEqual([
			{ primitive: 'grid', line: 1, text: '#grid(columns: (1fr, 1fr))[甲乙]' }
		]);
	});

	test('命中内容块写法 #grid[...]', () => {
		expect(findDroppedPrimitives('#place(top + right)[方块]')).toHaveLength(1);
	});

	test('命中方法调用链 .grid(...)', () => {
		expect(findDroppedPrimitives('#foo.grid(columns: 2)')).toHaveLength(1);
	});

	test('正文里裸写单词不算命中', () => {
		expect(findDroppedPrimitives('typst 的 grid 是排两栏的标准写法。')).toEqual([]);
	});

	test('行注释里的调用不算命中', () => {
		expect(findDroppedPrimitives('// 这里曾经用 #grid 排两栏')).toEqual([]);
	});

	test('块注释跨行时，后续行也不算命中', () => {
		const source = ['/* 下面这段是反例', '#place(top)[x]', '*/', '正文'].join('\n');
		expect(findDroppedPrimitives(source)).toEqual([]);
	});

	test('字符串与原始文本里的名字不算命中', () => {
		expect(findDroppedPrimitives('#text("用 #grid 会丢内容")')).toEqual([]);
		expect(findDroppedPrimitives('#raw("`#columns(2)`")')).toEqual([]);
	});

	test('一行里多个原语各自成一条，行号从 1 起', () => {
		const source = ['没问题', '#grid(columns: 2)[a]', '#stack(dir: ltr)[b]'].join('\n');
		expect(findDroppedPrimitives(source)).toEqual([
			{ primitive: 'grid', line: 2, text: '#grid(columns: 2)[a]' },
			{ primitive: 'stack', line: 3, text: '#stack(dir: ltr)[b]' }
		]);
	});

	test('八个被丢弃的原语全部认得', () => {
		const source = [
			'#grid(columns: 2)[a]',
			'#place(top)[a]',
			'#columns(2)[a]',
			'#rect(width: 1pt)[a]',
			'#line(length: 1pt)',
			'#stack(dir: ltr)[a]',
			'#align(center)[a]',
			'#v(1em)'
		].join('\n');
		expect(findDroppedPrimitives(source).map((hit) => hit.primitive)).toEqual([
			'grid',
			'place',
			'columns',
			'rect',
			'line',
			'stack',
			'align',
			'v'
		]);
	});

	test('语义元素不在名单里', () => {
		expect(findDroppedPrimitives('#table(columns: (1fr,))[a]\n#figure([a])\n#quote[a]')).toEqual(
			[]
		);
	});

	/**
	 * 有意不拦的形态：按导出目标分流时，`grid` 出现在 else 分支里且不带 `#`。
	 * `content/cv.typ` 的 `site-columns` 正是这么写的 —— 那是正确用法，因为
	 * HTML 目标走的是 `html.elem`，`grid` 只在 PDF 目标下才会执行。
	 *
	 * 代价是这一层拦不住「写在代码块里、但没做 target 分流」的误用。它是安全网，
	 * 不是证明 —— 想彻底拦住得解析语法树，对一个只用来防手滑的检查不值得。
	 */
	test('代码块里不带 # 的调用不拦（target 分流靠这条放行）', () => {
		const source = [
			'#let cols(..body) = context {',
			'  if target() == "html" {',
			'    html.elem("div", body.pos().join())',
			'  } else {',
			'    grid(columns: (1fr, 2.4fr), ..body.pos())',
			'  }',
			'}'
		].join('\n');
		expect(findDroppedPrimitives(source)).toEqual([]);
	});
});

/**
 * markdown 写法检查 —— 这几条被反复踩到，所以做成测试而不是靠记性。
 *
 * 它们共同的特征是**静默失效**：typst 不认，但也不报错（或只给一条含糊的
 * "no text within stars"），于是错的东西直接出现在页面上。
 */
describe('findMarkdownIsms', () => {
	test('双星号粗体：typst 用单星号', () => {
		expect(findMarkdownIsms('这是**重点**内容').map((h) => h.kind)).toEqual(['**']);
	});

	test('井号标题：typst 用等号', () => {
		expect(findMarkdownIsms('## 小节').map((h) => h.kind)).toEqual(['##']);
		expect(findMarkdownIsms('### 更深').map((h) => h.kind)).toEqual(['##']);
	});

	test('行首的 > 引用：typst 用 #quote(block: true)', () => {
		expect(findMarkdownIsms('> 引用一句').map((h) => h.kind)).toEqual(['>']);
	});

	test('markdown 表格行', () => {
		expect(findMarkdownIsms('| 甲 | 乙 |').map((h) => h.kind)).toEqual(['|']);
	});

	/**
	 * 这条踩过：课件从 markdown 改写成 typst 之后，参考链接还是 `[文字](url)` 的写法。
	 * typst 不认，于是整段以字面字符出现在页面上，只在编译日志里留一条
	 * "no text within stars" —— 页面看着像「链接样式没生效」，不像错误。
	 */
	test('markdown 链接：[文字](url) 要写成 #link("url")[文字]', () => {
		expect(findMarkdownIsms('用 [typst](https://typst.app/) 写').map((h) => h.kind)).toEqual([
			'[]()'
		]);
		expect(findMarkdownIsms('见 [文档](/docs/x.md)').map((h) => h.kind)).toEqual(['[]()']);
		expect(findMarkdownIsms('- [`qb-open`](https://example.com/a/b.c) —— 启动器').map((h) => h.kind)).toEqual([
			'[]()'
		]);
	});

	test('typst 自己的链接写法不算、普通方括号不算', () => {
		expect(findMarkdownIsms('#link("https://typst.app/")[typst] 写')).toEqual([]);
		expect(findMarkdownIsms('列表项 [*甲*]，下一项 [*乙*]')).toEqual([]);
		expect(findMarkdownIsms('items.map(x => [是 #x])')).toEqual([]);
		expect(findMarkdownIsms('#list(..xs.map(v => [#v]))')).toEqual([]);
	});

	/** 代码围栏里的这些字符是终端输出和 diff，原样保留才是对的。 */
	test('代码块里的一律不算', () => {
		const source = ['```sh', '## 这是 shell 注释', '> 这是提示符', '| 这是管道 |', 'a**b', '```'].join('\n');
		expect(findMarkdownIsms(source)).toEqual([]);
	});

	test('正文里提到这些符号不算（只认行首的）', () => {
		expect(findMarkdownIsms('markdown 用 `##` 写标题，typst 用 `=`。')).toEqual([]);
		expect(findMarkdownIsms('箭头是 ->，比较是 >=。')).toEqual([]);
		expect(findMarkdownIsms('按位或是 | 号。')).toEqual([]);
	});

	test('行号从 1 起，带原文与原因', () => {
		const hit = findMarkdownIsms(['没问题', '这里有**粗体**'].join('\n'))[0];
		expect(hit.line).toBe(2);
		expect(hit.text).toBe('这里有**粗体**');
		expect(hit.reason).toContain('单星号');
	});
});

/**
 * content/ 下的每一份 .typ 都必须能安全导出成 HTML。
 *
 * 这条断言是这套预览管线唯一的静默失败通道的守门人：被丢弃的**容器**会连坐整棵
 * 子树，内容从页面上消失而 typst 只给一条通用 warning、退出码 0。与其等读者发现
 * 「怎么少了一段」，不如让测试先红。
 *
 * 报错信息里带上文件名、行号和原文，因为修的人需要立刻知道去哪儿改。
 */
describe('content/ 里的 typst 文档', () => {
	test('不包含任何会被 HTML 导出丢弃的摆放原语', async () => {
		const files = await collectTypstFiles(CONTENT_DIR);
		expect(files.length, 'content/ 下应当至少有一份 .typ').toBeGreaterThan(0);

		const problems: string[] = [];

		for (const relativePath of files) {
			const source = await readFile(join(CONTENT_DIR, relativePath), 'utf-8');
			for (const hit of findDroppedPrimitives(source)) {
				problems.push(`${relativePath}:${hit.line}: #${hit.primitive} 在 HTML 导出下会被丢弃`);
			}
		}

		expect(problems.join('\n')).toBe('');
	});

	test('不包含 markdown 写法（会静默失效或直接编译失败）', async () => {
		const files = await collectTypstFiles(CONTENT_DIR);
		const problems: string[] = [];

		for (const relativePath of files) {
			const source = await readFile(join(CONTENT_DIR, relativePath), 'utf-8');
			for (const hit of findMarkdownIsms(source)) {
				problems.push(`${relativePath}:${hit.line}: ${hit.kind} —— ${hit.reason}\n    ${hit.text}`);
			}
		}

		expect(problems.join('\n')).toBe('');
	});
});

/** 递归收集 content/ 下所有 .typ 的相对路径。点号开头的目录跳过，与建树规则一致。 */
async function collectTypstFiles(root: string, prefix = ''): Promise<string[]> {
	const entries = await readdir(join(root, prefix), { withFileTypes: true });
	const found: string[] = [];

	for (const entry of entries) {
		if (entry.name.startsWith('.')) continue;
		const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;

		if (entry.isDirectory()) {
			found.push(...(await collectTypstFiles(root, relativePath)));
		} else if (entry.name.endsWith('.typ')) {
			found.push(relativePath);
		}
	}

	return found;
}
