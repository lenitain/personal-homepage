import { describe, expect, test } from 'vitest';
import { access, readFile, readdir } from 'node:fs/promises';
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

/** 抽出标题文本。讲义里的标题缩进两层，所以行首允许空白。 */
function headings(source: string): string[] {
	return [...source.matchAll(/^\s*=+ (.+)$/gm)].map((match) => match[1].trim());
}

/**
 * 骨架：每一章要读起来是一条线，不是一份实验报告。
 *
 * 这一组来自一次真实的返工。第 4 章原来的节序是「1. 方法（含小节「延迟」）→
 * 2. 延迟 → 3. 系统调用 → 4. Python → 5. 我选了什么 → 6. 那个 bug → 7. 结论」：
 * 两个「延迟」挨着重名；机制那一段（动态链接器）埋在标题叫「延迟」的节里；
 * 而「抓出一个真 bug」是附录，却夹在决定和结论中间，把这条线截断了。
 * 这些在页面上全都看得出来，但没有任何东西会因此报错 —— 所以钉在这里。
 */
describe('章节骨架', () => {
	test('同一份文件里没有重名标题', async () => {
		const problems: string[] = [];

		for (const entry of all) {
			for (const name of [entry.file, entry.slide]) {
				const source = await readFile(join(COURSE_DIR, name), 'utf-8');
				const seen = new Set<string>();

				for (const heading of headings(source)) {
					if (seen.has(heading)) problems.push(`${name}: 「${heading}」出现了两次`);
					seen.add(heading);
				}
			}
		}

		expect(problems.join('\n')).toBe('');
	});

	test('每一章的节号从 1. 连续排到 n.，没有跳号', async () => {
		const problems: string[] = [];

		for (const entry of all) {
			const source = await readFile(join(COURSE_DIR, entry.file), 'utf-8');
			const numbers = [...source.matchAll(/^= (\d+)\./gm)].map((match) => Number(match[1]));
			const wanted = numbers.map((_, index) => index + 1);

			if (numbers.join(',') !== wanted.join(',')) {
				problems.push(`${entry.file}: 节号是 ${numbers.join(' ')}`);
			}
		}

		expect(problems.join('\n')).toBe('');
	});

	/**
	 * 讲义的最后一张要是结论。另外四份都以 `#punch` 收尾，而第 4 章曾经停在
	 * 「选 C，musl，静态」—— 讲完了决定，但没落地。
	 */
	test('每份讲义的最后一张是结论', async () => {
		const problems: string[] = [];

		for (const entry of all) {
			const source = await readFile(join(COURSE_DIR, entry.slide), 'utf-8');
			const lastSlide = source.slice(source.lastIndexOf('#slide['));

			if (!lastSlide.includes('#punch[')) problems.push(`${entry.slide}: 最后一张没有 #punch`);
		}

		expect(problems.join('\n')).toBe('');
	});
});

/**
 * 讲义与正文讲的必须是同一样东西。
 *
 * 「讲义缺信息」这件事没有单一的症状：引一个没介绍过的概念、指一支打不出这个数的
 * 脚本、把正文的读数抄成另一次运行的读数 —— 三种都发生过，而且都只有听众会发现。
 */
describe('讲义与正文引的是同一样东西', () => {
	test('正文和讲义里引的实验脚本都在磁盘上', async () => {
		const labs = join(process.cwd(), 'docs', 'labs', 'resident-browser');
		const missing: string[] = [];

		for (const entry of all) {
			for (const name of [entry.file, entry.slide]) {
				const source = await readFile(join(COURSE_DIR, name), 'utf-8');

				for (const match of source.matchAll(/docs\/labs\/resident-browser\/([\w.-]+\.sh)/g)) {
					try {
						await access(join(labs, match[1]));
					} catch {
						missing.push(`${name} → ${match[1]} 不存在`);
					}
				}
			}
		}

		expect(missing.join('\n')).toBe('');
	});

	/**
	 * 演示 07 的那两个数（静态 / 动态）会随机器动，所以正文和讲义必须引**同一次
	 * 运行**的读数 —— 否则听众在讲义上看到的和读到的对不上。曾经就这样：
	 * 正文 372 / 495，讲义 381 / 519。
	 */
	test('演示 07 的读数：正文和讲义是同一组，而且跟差值自洽', async () => {
		const pick = (source: string) => {
			const match = source.match(/静态\s*(\d+)\s*µs[、，,]\s*动态\s*(\d+)\s*µs/);
			return match ? { slow: Number(match[2]), fast: Number(match[1]) } : null;
		};

		const [doc, deck] = await Promise.all(
			['5-what-to-write-it-in.typ', 'slides/5-what-to-write-it-in.typ'].map((name) =>
				readFile(join(COURSE_DIR, name), 'utf-8')
			)
		);

		const pair = pick(doc);
		expect(pair, '正文里要贴演示 07 的两个读数').not.toBeNull();
		expect(pick(deck), '讲义要引同一组读数（不是另一次运行的）').toEqual(pair);
		expect(Number(doc.match(/多出来的\s*(\d+)\s*µs/)?.[1]), '差值是那两个数之差').toBe(
			pair!.slow - pair!.fast
		);
	});

	/**
	 * 那一张对比表是这一章要讲的东西本身，所以它整张进了讲义 ——
	 * 也正因为如此，它必须跟正文那两张表是同一批数，不能各写各的。
	 */
	test('讲义里那张对比表，跟正文的两张表是同一批数', async () => {
		const [doc, deck] = await Promise.all(
			['5-what-to-write-it-in.typ', 'slides/5-what-to-write-it-in.typ'].map((name) =>
				readFile(join(COURSE_DIR, name), 'utf-8')
			)
		);

		/** 正文里贴的两份输出：延迟（绑核最小值）和系统调用 / 地址空间。 */
		const latency = new Map<string, string>(
			[...doc.matchAll(/^\s+(qb-open-[\w-]+)\s+min=([\d.]+)/gm)].map(
				(match) => [match[1] ?? '', match[2] ?? ''] as const
			)
		);
		const runtime = new Map<string, { syscalls: string; vma: string }>(
			[
				...doc.matchAll(/^\s+(qb-open-[\w-]+)\s+p50=[\d.]+\s+syscalls=(\d+)\s+vma=(\d+)/gm)
			].map((match) => [
				match[1] ?? '',
				{ syscalls: match[2] ?? '', vma: match[3] ?? '' }
			] as const)
		);
		/** 体积那列是 strip 之后的字节数（正文贴的是原始字节，讲义换成 KB / MB）。 */
		const sizes = new Map<string, number>(
			[...doc.matchAll(/^\s+ok\s+(qb-open-[\w-]+)\s+as-built=\d+\s+stripped=(\d+)/gm)].map(
				(match) => [match[1] ?? '', Number(match[2])] as const
			)
		);

		const rows = [
			...deck.matchAll(
				/\[`(qb-open-[\w-]+)`\], \[[^\]]*\], \[([\d.]+)\], \[(\d+)\], \[(\d+)\], \[([\d.]+) (KB|MB)\]/g
			)
		];
		const problems: string[] = [];

		for (const [, name = '', min = '', syscalls = '', vma = '', size = '', unit = ''] of rows) {
			if (latency.get(name) !== min) {
				problems.push(`${name}: 讲义写延迟 ${min}，正文是 ${latency.get(name)}`);
			}

			const want = runtime.get(name);
			if (!want) problems.push(`${name}: 正文的系统调用表里没有这一行`);
			else if (want.syscalls !== syscalls || want.vma !== vma) {
				problems.push(
					`${name}: 讲义写 ${syscalls} 次调用 / ${vma} 个 VMA，正文是 ${want.syscalls} / ${want.vma}`
				);
			}

			const bytes = sizes.get(name);
			const scale = unit === 'MB' ? 1_000_000 : 1000;
			// 讲义把字节数换成人看的单位，写几位小数就按几位判舍入：
			// 「15 KB」允许 14.5–15.5（正文是 14632 字节），「8.9 KB」只允许 ±0.05。
			const decimals = size.includes('.') ? (size.split('.')[1] ?? '').length : 0;
			const tolerance = 0.5 * 10 ** -decimals;
			if (bytes === undefined) problems.push(`${name}: 正文的体积表里没有这一行`);
			else if (Math.abs(Number(size) - bytes / scale) > tolerance) {
				problems.push(`${name}: 讲义写 ${size} ${unit}，正文是 ${bytes} 字节`);
			}
		}

		expect(runtime.size, '正文里那张系统调用表应当有九行').toBe(9);
		expect(rows.length, '讲义那张表要覆盖到九个实现').toBe(runtime.size);
		expect(latency.size, '正文的两张表行数要对得上').toBe(runtime.size);
		expect(sizes.size, '正文的体积表也要有九行').toBe(runtime.size);
		expect(problems.join('\n')).toBe('');
	});

	/**
	 * 缩写不许裸用 —— 判的是**同一张幻灯片 / 同一节**，不是整份文件。
	 *
	 * 这条的起因很直接：讲义那张对比表新加了一列 `VMA`，然后有人问「vma 是什么」。
	 * 表格里、表旁边的注里都没有一句话说它是什么 —— 而这份讲义别处确实写着
	 * 「地址空间里 9 个区间」，所以「整份文件里出现过『区间』」那种松判法挡不住它。
	 * 缩写对作者是常识，对听众是一堵墙。
	 */
	test('用 VMA 的那一块内容里，得说明它是什么', async () => {
		const names = [
			...new Set([
				...all.flatMap((entry) => [entry.file, entry.slide]),
				'index.typ',
				'slides/index.typ'
			])
		];
		const problems: string[] = [];

		for (const name of names) {
			const source = await readFile(join(COURSE_DIR, name), 'utf-8');
			// 讲义按 `#slide[` 一张一张切，正文按 `= ` 一节一节切。
			const blocks = source.split(name.startsWith('slides/') ? '#slide[' : /^= /m);

			for (const block of blocks) {
				if (/\bVMA\b/.test(block) && !/虚拟内存区域|virtual memory area|区间/.test(block)) {
					problems.push(`${name}: 有一块内容用了 VMA，却没在同一张 / 同一节里说它是什么`);
				}
			}
		}

		expect(problems.join('\n')).toBe('');
	});

	test('引用 377.6 的地方同时给出它的口径', async () => {
		const problems: string[] = [];

		for (const entry of [all[0], ...numbered]) {
			for (const name of [entry.file, entry.slide]) {
				const source = await readFile(join(COURSE_DIR, name), 'utf-8');
				if (!source.includes('377.6')) continue;
				if (!/最小值|绑核/.test(source)) problems.push(`${name}: 用了 377.6 却没说它是绑核最小值`);
			}
		}

		expect(problems.join('\n')).toBe('');
	});

	/**
	 * 实验脚本开头那行「对应《某章》第 N 节「标题」」。
	 *
	 * 章节里加一节、挪一节，这些行就悄悄指错了地方 —— 已经错过一次：
	 * 第 2 章开头补了「父进程死了子进程不会跟着死」之后，所有节号顺延，
	 * 而 `14-identity-channels.sh` 还写着「第 4 节」。它在 `docs/` 里，
	 * 没有任何页面对得出来。
	 */
	test('实验脚本指的那一节，标题真的在那一节里', async () => {
		const labs = join(process.cwd(), 'docs', 'labs', 'resident-browser');
		const problems: string[] = [];

		for (const name of (await readdir(labs)).filter((file) => file.endsWith('.sh'))) {
			const source = await readFile(join(labs, name), 'utf-8');
			const ref = source.match(/对应《(.+?)》第 (\d+) 节「(.+?)」/);
			if (!ref) continue;

			const [, title, section, heading] = ref;
			// 脚本里允许用章标题的简称（序的标题带着「，我该怎么办？」那一问）。
			const entry = all.find((item) => item.title.startsWith(title));
			if (!entry) {
				problems.push(`${name}: 引的《${title}》不是任何一章的标题`);
				continue;
			}

			const chapter = await readFile(join(COURSE_DIR, entry.file), 'utf-8');
			const target = chapter.split(/^= /m).find((part) => part.startsWith(`${section}. `));
			if (!target) problems.push(`${name}: ${entry.file} 里没有第 ${section} 节`);
			else if (!target.includes(heading)) {
				problems.push(`${name}: 《${title}》第 ${section} 节里没有「${heading}」`);
			}
		}

		expect(problems.join('\n')).toBe('');
	});
});
