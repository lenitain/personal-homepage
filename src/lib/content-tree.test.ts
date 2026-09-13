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

	test('只收 .md / .typ，别的文件一概不进树', async () => {
		await writeFixture('readme.md');
		await writeFixture('notes.txt');
		await writeFixture('cv.typ', '= CV\n');
		await writeFixture('cv.pdf', '%PDF-1.7 not really');
		await writeFixture('blog/why-yazi.md');
		await writeFixture('blog/diagram.png');

		const entries = await readContentTree(contentDir);

		expect(entries.map((entry) => entry.name)).toEqual(['blog', 'cv.typ', 'readme.md']);
		expect(entries[0].children?.map((child) => child.name)).toEqual(['why-yazi.md']);
	});

	test('点号开头的文件与目录都不进树', async () => {
		await writeFixture('readme.md');
		await writeFixture('.draft.md');
		await writeFixture('.hidden/notes.md');
		await writeFixture('blog/.draft.typ', '= D\n');
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

	test('markdown 内联的是源文本', async () => {
		await writeFixture('readme.md', '# hello\n');

		const [readme] = await readContentTree(contentDir);

		expect(readme.type).toBe('file');
		expect(readme.content).toBe('# hello\n');
		expect(readme.mtime).toMatch(/^\d{4}-\d{2}-\d{2}T/);
	});

	test('typst 内联的是渲染好的 HTML 片段，不是源文本', async () => {
		await writeFixture('cv.typ', '= Title\n\nBody text\n');

		const [cv] = await readContentTree(contentDir);

		expect(cv.content).toContain('<h2>Title</h2>');
		expect(cv.content).toContain('Body text');
		// 源文本里那行 `= Title` 不该原样出现在产物里
		expect(cv.content).not.toContain('= Title');
		expect(cv.error).toBeUndefined();
	});

	test('渲染失败的 typst 没有 content，只有 error 诊断', async () => {
		await writeFixture('broken.typ', '= Hi\n#let x = \n');

		const [broken] = await readContentTree(contentDir);

		expect(broken.content).toBeUndefined();
		expect(broken.error?.join('\n')).toContain('broken.typ:2');
	});

	test('size 是字节数，不是字符数', async () => {
		await writeFixture('readme.md', '# 你好\n');

		const [readme] = await readContentTree(contentDir);

		expect(readme.size).toBe(9);
		expect(readme.content?.length).toBe(5);
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
