import { describe, expect, test } from 'vitest';
import { access, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { CONTENT_DIR } from './content-dir.server';
import { renderTypstDocument } from './typst-compile';

/**
 * 课件导航的一致性 —— 把「手抄了五遍的章节目录」变成会红的测试。
 *
 * ## 为什么值得单独一个测试
 *
 * 这批课件的章节引用散在五个地方：入口的章节目录、讲义封面的章节列表、
 * 每一章结尾的「下一章」、每一章正文里的回指、实验 README 的脚本对照表。
 * 它们曾经真的各写各的，于是同一件事在入口被记成「第一章」、在正文里其实
 * 在第三章；同一个内存数字在入口和正文里差了 11 MiB；讲义说「四章」而文档
 * 有五章。**全都不报错** —— 只有读者会发现。
 *
 * 现在章号只在 `.syllabus.typ` 里出现一次，入口和讲义都从它生成。这个测试
 * 钉住三件不能靠记性的事：
 *
 * 1. 数据里写的每一份文件都真的在磁盘上（改文件名忘了改数据）
 * 2. 每一章自己声明的章号跟数据一致（改了数据忘了改正文）
 * 3. 引用别章的正文写的是「数据里的那个标题」，不是手打的名字
 */

const COURSE_DIR = join(CONTENT_DIR, 'hacks', 'resident-browser');
const SYLLABUS = join(COURSE_DIR, '.syllabus.typ');

interface ChapterEntry {
	/** `none` 表示这一节是序，不计入章数。 */
	n: string | null;
	file: string;
	slide: string;
	title: string;
}

/** 从 `.syllabus.typ` 里抠出章节目录。数据是字面量，正则足够，不必起 typst。 */
function parseSyllabus(source: string): ChapterEntry[] {
	const entries: ChapterEntry[] = [];

	for (const block of source.split('\n  (\n').slice(1)) {
		const body = block.slice(0, block.indexOf('\n  ),'));
		const field = (name: string) => body.match(new RegExp(`\\b${name}: "([^"]+)"`))?.[1];
		const n = body.match(/\bn: (none|"[^"]+")/)?.[1];

		entries.push({
			n: n === 'none' || n === undefined ? null : n.replaceAll('"', ''),
			file: field('file') ?? '',
			slide: field('slide') ?? '',
			title: field('title') ?? ''
		});
	}

	return entries;
}

const syllabusSource = await readFile(SYLLABUS, 'utf-8');
const all = parseSyllabus(syllabusSource);
const numbered = all.filter((entry) => entry.n !== null);

describe('syllabus.typ 本身', () => {
	test('解析出了条目，而且第一节是序', () => {
		expect(all.length, '应当解析出若干章节条目').toBeGreaterThan(4);
		expect(all[0].n, '第一节是序（n: none）').toBeNull();
	});

	test('四章：正文章节数与讲义里的「四章」一致', () => {
		expect(numbered).toHaveLength(4);
	});

	test('章号从 1. 连续排到 4.，没有重号', () => {
		expect(numbered.map((entry) => entry.n)).toEqual(['1.', '2.', '3.', '4.']);
	});

	test('每一节都有标题、正文文件和讲义文件', () => {
		for (const entry of all) {
			expect(entry.title, `${entry.file} 缺标题`).not.toBe('');
			expect(entry.file, `${entry.title} 缺正文文件名`).not.toBe('');
			expect(entry.slide, `${entry.title} 缺讲义文件名`).not.toBe('');
		}
	});
});

describe('章节文件', () => {
	test('数据里写的正文与讲义文件都在磁盘上', async () => {
		const missing: string[] = [];

		for (const entry of all) {
			for (const relative of [entry.file, entry.slide]) {
				try {
					await access(join(COURSE_DIR, relative));
				} catch {
					missing.push(`${entry.title} → ${relative}`);
				}
			}
		}

		expect(missing.join('\n')).toBe('');
	});

	/**
	 * 每一章的**序言第一段**会点名上一章（「《谁来释放资源》把释放资源的人定了」）。
	 * 这一条钉住那些回指里的章号真的存在，而且引用走统一的写法 ——
	 * 手打标题的后果是改标题时漏掉引用，而页面上看不出来。
	 */
	test('引用别章时走 #chapterRef(...)，且章号存在', async () => {
		const numbered = all.filter((entry) => entry.n !== null);
		const problems: string[] = [];

		for (const entry of all) {
			const source = await readFile(join(COURSE_DIR, entry.file), 'utf-8');

			for (const match of source.matchAll(/#chapterRef\("(\d)\."\)/g)) {
				const index = Number(match[1]);
				if (!numbered[index - 1]) {
					problems.push(`${entry.file}: 引用了不存在的第 ${index} 章`);
				}
			}

			// 书名号里的标题只能由 #chapterRef / #prefaceRef 生成。
			// 手打一份出来就是「两处真相」，改标题时必然漂移。
			for (const title of all.map((item) => item.title)) {
				if (source.includes(`《${title}》`)) {
					problems.push(`${entry.file}: 手打了《${title}》，应当用 #chapterRef(...)`);
				}
			}
		}

		expect(problems.join('\n')).toBe('');
	});
});

/**
 * 入口与讲义里的**结论性数字**。
 *
 * 这几个数被抄到过三份文件里，而且真的漂移过（入口写 140 MiB、正文写 129 MiB）。
 * 它们各自只有一个来处，所以钉在生成它们的那些文件上：入口页负责「拿结果说事」，
 * 各章负责「量出来是什么」。
 */
describe('数字', () => {
	test('入口页用的是量出来的 129 MiB，不是印象里的 140', async () => {
		const index = await readFile(join(COURSE_DIR, 'index.typ'), 'utf-8');

		expect(index).toContain('129 MiB');
		expect(index, '“140 MiB” 是旧稿遗留的数字').not.toContain('140 MiB');
	});

	test('常驻成本在入口与两章正文里是同一个数', async () => {
		const sources = await Promise.all(
			['index.typ', '2-when-to-daemonize.typ', '4-what-deserves-ram.typ'].map((name) =>
				readFile(join(COURSE_DIR, name), 'utf-8')
			)
		);

		for (const source of sources) {
			expect(source).toContain('129 MiB');
		}
	});

	test('启动器延迟与它出现的地方一致（377.6 µs 最小值口径）', async () => {
		const [ch4, index] = await Promise.all(
			['5-what-to-write-it-in.typ', 'index.typ'].map((name) =>
				readFile(join(COURSE_DIR, name), 'utf-8')
			)
		);

		expect(ch4).toContain('377.6');
		expect(index).toContain('377.6');
	});

	test('入口页说明了启动器延迟的测量口径（免得跟 measure.sh 的 p50 混起来）', async () => {
		const index = await readFile(join(COURSE_DIR, 'index.typ'), 'utf-8');

		expect(index).toContain('latency.sh');
		expect(index).toContain('measure.sh');
	});
});

/**
 * 渲染出来的样子 —— 这几条是「只有对着页面才看得出来」的错误。
 *
 * 这一条是真发生过的：`《#chapter("1.").title》` 渲染成双层书名号
 * 《《什么样的程序值得常驻》》—— 模板自带 `《》`，调用处又写了一遍，
 * 两种写法各自都「看着对」，只有渲染出来才露馅。
 */
describe('渲染结果', () => {
	test('每一章的正文里，书名号都是单层、且指向真实的章标题', async () => {
		const titles = all.map((entry) => entry.title);
		const problems: string[] = [];

		for (const entry of all) {
			const result = await renderTypstDocument({
				contentDir: CONTENT_DIR,
				documentPath: `hacks/resident-browser/${entry.file}`
			});

			expect(result.ok, `${entry.file} 渲染失败：${result.diagnostics.join('\n')}`).toBe(true);
			if (!result.ok) continue;

			const text = stripTags(result.html);

			if (text.includes('《《') || text.includes('》》')) {
				problems.push(`${entry.file}: 出现双层书名号`);
			}
			if (text.includes('#chapterRef')) {
				problems.push(`${entry.file}: 章引用没有被求值`);
			}

			for (const match of text.matchAll(/《([^《》]+)》/g)) {
				if (!titles.includes(match[1])) {
					problems.push(`${entry.file}: 书名号里的「${match[1]}」不是任何一章的标题`);
				}
			}
		}

		expect(problems.join('\n')).toBe('');
	});
});

/** 只留文本，判「页面上看得见什么」。 */
function stripTags(html: string): string {
	return html
		.replace(/<[^>]+>/g, '')
		.replaceAll('&lt;', '<')
		.replaceAll('&gt;', '>')
		.replaceAll('&amp;', '&');
}

/**
 * 入口与讲义都从 `.syllabus.typ` 生成章节列表，而不再各自维护一份。
 * 这条钉住那个「单一真相源」的关系本身。
 */
describe('导航的单一真相源', () => {
	test('入口与讲义都 import 了 syllabus', async () => {
		const [index, deckIndex] = await Promise.all(
			['index.typ', 'slides/index.typ'].map((name) => readFile(join(COURSE_DIR, name), 'utf-8'))
		);

		expect(index).toContain('.syllabus.typ');
		expect(deckIndex).toContain('.syllabus.typ');
	});

	test('入口不再手写章节目录（标题只在 syllabus 里出现）', async () => {
		const index = await readFile(join(COURSE_DIR, 'index.typ'), 'utf-8');

		for (const entry of numbered) {
			expect(index, `入口不该手打《${entry.title}》`).not.toContain(`《${entry.title}》`);
		}
	});
});
