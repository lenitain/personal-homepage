import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from 'vitest';
import { readContentTree } from './content-tree';

let contentDir: string;

beforeEach(async () => {
	contentDir = await mkdtemp(join(tmpdir(), 'content-tree-'));
});

afterEach(async () => {
	await rm(contentDir, { recursive: true, force: true });
});

/** 在临时 content/ 里造一个文件，中间目录按需创建。 */
async function writeFixture(relativePath: string, body = '# hi\n'): Promise<void> {
	const fullPath = join(contentDir, relativePath);
	await mkdir(dirname(fullPath), { recursive: true });
	await writeFile(fullPath, body, 'utf-8');
}

describe('readContentTree', () => {
	test('目录排在文件前面，各自按名称字母序', async () => {
		await writeFixture('readme.md');
		await writeFixture('blog/why-yazi.md');
		await writeFixture('about/me.md');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['about', 'blog', 'readme.md']);
	});

	test('同层文件也按字母序，不管写的先后', async () => {
		await writeFixture('blog/why-yazi.md');
		await writeFixture('blog/chalk-on-the-web.md');

		const [blog] = await readContentTree(contentDir);

		expect(blog.children?.map((child) => child.name)).toEqual([
			'chalk-on-the-web.md',
			'why-yazi.md'
		]);
	});

	test('path 是相对 content/ 的路径，不是绝对路径', async () => {
		await writeFixture('blog/why-yazi.md');

		const [blog] = await readContentTree(contentDir);

		expect(blog.path).toBe('blog');
		expect(blog.children?.[0].path).toBe('blog/why-yazi.md');
	});

	test('只收 .md / .typ / .pdf，别的文件一概不进树', async () => {
		await writeFixture('readme.md');
		await writeFixture('notes.txt');
		await writeFixture('cv.typ');
		await writeFixture('cv.pdf');
		await writeFixture('blog/why-yazi.md');
		await writeFixture('blog/diagram.png');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['blog', 'cv.pdf', 'cv.typ', 'readme.md']);
		expect(entries[0].children?.map((child) => child.name)).toEqual(['why-yazi.md']);
	});

	test('点号开头的文件与目录都不进树 —— typst 编译的 wrapper 就是隐藏文件', async () => {
		await writeFixture('readme.md');
		await writeFixture('.preview-a1b2.typ');
		await writeFixture('.hidden/notes.md');
		await writeFixture('blog/.preview-c3d4.typ');
		await writeFixture('blog/why-yazi.md');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['blog', 'readme.md']);
		expect(entries[0].children?.map((child) => child.name)).toEqual(['why-yazi.md']);
	});

	test('一个可预览文件都没有的目录整支被跳过', async () => {
		await writeFixture('about/me.md');
		await writeFixture('empty-dir/.keep');
		await writeFixture('only-text/notes.txt');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['about']);
	});

	test('只装着子目录的目录会被保留', async () => {
		await writeFixture('projects/dotfiles/aliases.md');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['projects']);
		expect(entries[0].children?.map((child) => child.name)).toEqual(['dotfiles']);
		expect(entries[0].children?.[0].children?.[0].path).toBe('projects/dotfiles/aliases.md');
	});

	test('文件带着正文和 ISO 格式的修改时间', async () => {
		await writeFixture('readme.md', '# hello\n');

		const [readme] = await readContentTree(contentDir);

		expect(readme.type).toBe('file');
		expect(readme.content).toBe('# hello\n');
		expect(readme.mtime).toMatch(/^\d{4}-\d{2}-\d{2}T/);
	});

	test('size 是字节数，不是字符数', async () => {
		await writeFixture('readme.md', '# 你好\n');

		const [readme] = await readContentTree(contentDir);

		expect(readme.size).toBe(9);
		expect(readme.content?.length).toBe(5);
	});

	test('只有 markdown 内联正文，typst 与 pdf 不带 content', async () => {
		await writeFixture('readme.md', '# hi\n');
		await writeFixture('cv.typ', '= CV\n');
		await writeFixture('cv.pdf', '%PDF-1.7 not really');

		const entries = await readContentTree(contentDir);
		const byName = new Map(entries.map((entry) => [entry.name, entry]));

		expect(byName.get('readme.md')?.content).toBe('# hi\n');
		expect(byName.get('cv.typ')?.content).toBeUndefined();
		expect(byName.get('cv.pdf')?.content).toBeUndefined();
	});

	test('目录不带 size', async () => {
		await writeFixture('blog/why-yazi.md');

		const [blog] = await readContentTree(contentDir);

		expect(blog.size).toBeUndefined();
	});

	test('空的 content/ 吐出空数组', async () => {
		expect(await readContentTree(contentDir)).toEqual([]);
	});
});
