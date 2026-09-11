import { describe, expect, test } from 'vitest';
import { findFileTreeEntry, flattenFileTree } from './file-tree';
import type { FsEntry } from './types';

function markdownFile(name: string, path: string): FsEntry {
	return { path, name, type: 'file', content: `# ${name}\n` };
}

function directory(name: string, path: string, children: FsEntry[]): FsEntry {
	return { path, name, type: 'dir', children };
}

/** 跟 content/ 同构的一棵小树：根上 2 个目录 + 1 篇 readme，共 4 篇文章。 */
function sampleTree(): FsEntry {
	return directory('~', '', [
		directory('blog', 'blog', [
			markdownFile('chalk-on-the-web.md', 'blog/chalk-on-the-web.md'),
			markdownFile('why-yazi.md', 'blog/why-yazi.md')
		]),
		directory('projects', 'projects', [markdownFile('dotfiles.md', 'projects/dotfiles.md')]),
		markdownFile('readme.md', 'readme.md')
	]);
}

function pathsOf(rows: ReturnType<typeof flattenFileTree>): string[] {
	return rows.map((row) => row.entry.path);
}

describe('flattenFileTree', () => {
	test('什么都不展开时，只吐出根的直接子节点', () => {
		const rows = flattenFileTree(sampleTree(), new Set());

		expect(pathsOf(rows)).toEqual(['blog', 'projects', 'readme.md']);
		expect(rows.every((row) => row.depth === 0)).toBe(true);
	});

	test('展开一个目录后，它的子节点紧跟在该目录之后、深度加一', () => {
		const rows = flattenFileTree(sampleTree(), new Set(['blog']));

		expect(pathsOf(rows)).toEqual([
			'blog',
			'blog/chalk-on-the-web.md',
			'blog/why-yazi.md',
			'projects',
			'readme.md'
		]);
		expect(rows.map((row) => row.depth)).toEqual([0, 1, 1, 0, 0]);
	});

	test('行的 expanded 标记跟着展开集合走，文件永远是 false', () => {
		const rows = flattenFileTree(sampleTree(), new Set(['projects']));
		const rowsByPath = new Map(rows.map((row) => [row.entry.path, row]));

		expect(rowsByPath.get('projects')?.expanded).toBe(true);
		expect(rowsByPath.get('blog')?.expanded).toBe(false);
		expect(rowsByPath.get('readme.md')?.expanded).toBe(false);
	});

	test('展开集合里的陌生路径不会凭空多出行来', () => {
		const rows = flattenFileTree(sampleTree(), new Set(['nope', 'blog/why-yazi.md']));

		expect(pathsOf(rows)).toEqual(['blog', 'projects', 'readme.md']);
	});

	test('空树吐出空数组', () => {
		const emptyRoot = directory('~', '', []);

		expect(flattenFileTree(emptyRoot, new Set())).toEqual([]);
		expect(flattenFileTree(emptyRoot, new Set(['whatever']))).toEqual([]);
	});
});

describe('findFileTreeEntry', () => {
	test('能找到深层节点', () => {
		const found = findFileTreeEntry(sampleTree(), 'blog/why-yazi.md');

		expect(found?.name).toBe('why-yazi.md');
		expect(found?.type).toBe('file');
	});

	test('根节点可以用空串找到', () => {
		expect(findFileTreeEntry(sampleTree(), '')?.name).toBe('~');
	});

	test('路径不存在时返回 null', () => {
		expect(findFileTreeEntry(sampleTree(), 'blog/missing.md')).toBeNull();
		expect(findFileTreeEntry(sampleTree(), 'blog/why-yazi.md/nested')).toBeNull();
	});
});
