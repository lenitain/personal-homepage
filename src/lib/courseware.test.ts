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
	/**
	 * 这几条钉的不是「某个数等于多少」，而是**正文与它引用的实验是同一批数**。
	 *
	 * 起因：正文曾经把「常驻 129 MiB」写成一个固定事实，而实验的重跑给出 136 MiB；
	 * 「六个进程的 Pss 是 0.2 MiB」和实验输出也有过 35 / 36 KiB 的差别。
	 * 这类数都跟着机器状态动，所以规矩是：
	 *
	 *   - **会动的数**：正文只给量级或范围，精确值只在实验输出里（那里每次都是现读的）
	 *   - **不变的数**（口径、比例、件数）：正文和实验必须逐字一致
	 *
	 * 于是测试只钉「不变的数」，以及「会动的数没有被写死成某一个值」。
	 */
	test('正文没把会随机器变的数字写死', async () => {
		const ch1 = await readFile(join(COURSE_DIR, '1-my-browser-is-slow.typ'), 'utf-8');
		const index = await readFile(join(COURSE_DIR, 'index.typ'), 'utf-8');

		expect(index, '“140 MiB” 是旧稿遗留的数字').not.toContain('140 MiB');
		expect(index, '常驻成本应当写成量级，而不是某一个读数').not.toMatch(
			/\[常驻成本\], \[0\], \[1\d\d MiB\]/
		);

		// 贴进正文的实验输出是某一次运行的样子，所以旁边必须说清「它会动」，
		// 否则读者会把它当成一个常量 —— 这正是当初 129 / 136 那次漂移的来源。
		expect(ch1, '六个进程那份实验输出旁边要交底「数会动」').toContain('在 35 到 40 KiB 之间跳');

		const ch3 = await readFile(join(COURSE_DIR, '4-what-deserves-ram.typ'), 'utf-8');
		expect(ch3, '贴实验输出的那一处要交底它会跟着机器状态动').toMatch(
			/跟着机器状态动|量级和那个差值/
		);
	});

	test('演示 12 的输出只贴一处，且两个读数差得不离谱', async () => {
		// 第 2 章把这份输出压成了一句话（只给量级），精确读数留在第 3 章 ——
		// 同一批数贴两遍，正是当初 129 / 136 漂移的来源。
		const ch2 = await readFile(join(COURSE_DIR, '2-when-to-daemonize.typ'), 'utf-8');
		const ch3 = await readFile(join(COURSE_DIR, '4-what-deserves-ram.typ'), 'utf-8');

		expect(ch2, '第 2 章只给量级，不再贴实验输出').not.toMatch(/空 profile\s+\d+ MiB/);
		expect(ch2, '第 2 章要指向量它的那个脚本').toContain('12-resident-memory.sh');

		const blank = ch3.match(/空 profile\s+(\d+) MiB/)?.[1];
		const real = ch3.match(/真实 profile\s+(\d+) MiB/)?.[1];
		expect(blank, '演示 12 的输出里应当有「空 profile」那一行').toBeTruthy();
		expect(real, '演示 12 的输出里应当有「真实 profile」那一行').toBeTruthy();
		expect(Number(real), '真实 profile 只该比空 profile 多几兆').toBeGreaterThan(Number(blank));
		expect(Number(real) - Number(blank)).toBeLessThanOrEqual(5);
	});

	test('常驻底价在正文里是同一个量级说法', async () => {
		const index = await readFile(join(COURSE_DIR, 'index.typ'), 'utf-8');

		expect(index).toContain('一百多 MiB');
		expect(index, '口径要写清楚，否则读者会把两种量法的数混起来').toContain('latency.sh');
		expect(index).toContain('measure.sh');
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

	test('启动时间在正文、讲义、入口里是同一个区间', async () => {
		const sources = await Promise.all(
			['1-my-browser-is-slow.typ', 'slides/1-my-browser-is-slow.typ', 'index.typ'].map((name) =>
				readFile(join(COURSE_DIR, name), 'utf-8')
			)
		);

		for (const source of sources) {
			expect(source, '启动时间的区间要一致').toContain('1.2 到 1.9 秒');
		}
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
