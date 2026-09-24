import { describe, expect, test } from 'vitest';
import { PAGE_STEP, arrowLeft, arrowRight, stepCursorPath, typeAheadPath } from './tree-nav';
import { flattenFileTree } from './file-tree';
import type { FsEntry, TreeRow } from './types';

function markdownFile(name: string, path: string): FsEntry {
	return { path, name, type: 'file', content: `# ${name}\n` };
}

function directory(name: string, path: string, children: FsEntry[]): FsEntry {
	return { path, name, type: 'dir', children };
}

/** 跟 content/ 同构的骨架：两层目录 + 两篇顶层文件。 */
function sampleTree(): FsEntry {
	return directory('~', '', [
		directory('blog', 'blog', [
			markdownFile('chalk-on-the-web.md', 'blog/chalk-on-the-web.md'),
			markdownFile('why-yazi.md', 'blog/why-yazi.md')
		]),
		directory('hacks', 'hacks', [
			directory('resident-browser', 'hacks/resident-browser', [
				markdownFile('index.typ', 'hacks/resident-browser/index.typ')
			])
		]),
		markdownFile('readme.md', 'readme.md'),
		markdownFile('cv.typ', 'cv.typ')
	]);
}

function rows(expanded: string[] = []): TreeRow[] {
	return flattenFileTree(sampleTree(), new Set(expanded));
}

/**
 * 全展开时的可见行，测试断言都以它为准：
 * blog → chalk → why-yazi → hacks → resident-browser → index.typ → readme.md → cv.typ
 */
function allRows(): TreeRow[] {
	return rows(['blog', 'hacks', 'hacks/resident-browser']);
}

describe('stepCursorPath', () => {
	test('下移一格', () => {
		expect(stepCursorPath(allRows(), 'blog', 'readme.md', 1)).toBe('blog/chalk-on-the-web.md');
	});

	test('上移一格', () => {
		expect(stepCursorPath(allRows(), 'blog/chalk-on-the-web.md', 'readme.md', -1)).toBe('blog');
	});

	test('移到底就停住，不越界', () => {
		expect(stepCursorPath(allRows(), 'cv.typ', 'readme.md', 1)).toBe('cv.typ');
		expect(stepCursorPath(allRows(), 'blog', 'readme.md', 100)).toBe('cv.typ');
		expect(stepCursorPath(allRows(), 'blog', 'readme.md', -100)).toBe('blog');
	});

	test('没有光标时，第一次移动落到正在读的那篇', () => {
		expect(stepCursorPath(allRows(), null, 'hacks/resident-browser/index.typ', 1)).toBe(
			'hacks/resident-browser/index.typ'
		);
		expect(stepCursorPath(allRows(), null, 'hacks/resident-browser/index.typ', -1)).toBe(
			'hacks/resident-browser/index.typ'
		);
	});

	test('没有光标、正在读的那篇又不可见：往下落到头，往上落到尾', () => {
		expect(stepCursorPath(rows(), null, 'hacks/resident-browser/index.typ', 1)).toBe('blog');
		expect(stepCursorPath(rows(), null, 'hacks/resident-browser/index.typ', -1)).toBe('cv.typ');
	});

	test('树是空的就没有落点', () => {
		expect(stepCursorPath([], 'blog', 'readme.md', 1)).toBeNull();
	});

	test('PageDown 一次跳 PAGE_STEP 行，同样夹住', () => {
		expect(stepCursorPath(allRows(), 'blog', 'readme.md', PAGE_STEP)).toBe('cv.typ');
	});
});

describe('arrowRight', () => {
	test('折叠的目录：原地展开，光标不动', () => {
		expect(arrowRight(rows(), 'blog')).toEqual({ kind: 'expand', path: 'blog' });
	});

	test('展开的目录：走进第一个子项', () => {
		expect(arrowRight(allRows(), 'hacks')).toEqual({
			kind: 'focus',
			path: 'hacks/resident-browser'
		});
	});

	test('展开了但没有子项的目录：不动', () => {
		const tree = directory('~', '', [
			directory('empty', 'empty', []),
			markdownFile('a.md', 'a.md')
		]);
		const visible = flattenFileTree(tree, new Set(['empty']));
		expect(arrowRight(visible, 'empty')).toBeNull();
	});

	test('文件：不动', () => {
		expect(arrowRight(allRows(), 'readme.md')).toBeNull();
	});

	test('没有光标：不动', () => {
		expect(arrowRight(allRows(), null)).toBeNull();
	});
});

describe('arrowLeft', () => {
	test('文件：跳到父目录', () => {
		expect(arrowLeft(allRows(), 'hacks/resident-browser/index.typ')).toEqual({
			kind: 'focus',
			path: 'hacks/resident-browser'
		});
	});

	test('折叠的目录：跳到父目录', () => {
		expect(arrowLeft(rows(['hacks']), 'hacks/resident-browser')).toEqual({
			kind: 'focus',
			path: 'hacks'
		});
	});

	test('展开的目录：原地收起', () => {
		expect(arrowLeft(rows(['hacks']), 'hacks')).toEqual({ kind: 'collapse', path: 'hacks' });
	});

	test('顶层的行（没有父）：不动', () => {
		expect(arrowLeft(allRows(), 'readme.md')).toBeNull();
		expect(arrowLeft(rows(), 'blog')).toBeNull();
	});

	test('没有光标：不动', () => {
		expect(arrowLeft(allRows(), null)).toBeNull();
	});
});

describe('typeAheadPath', () => {
	test('从光标往下找，大小写不敏感', () => {
		expect(typeAheadPath(allRows(), 'blog', 'c')).toBe('blog/chalk-on-the-web.md');
		expect(typeAheadPath(allRows(), 'blog', 'C')).toBe('blog/chalk-on-the-web.md');
	});

	test('找到底就绕回开头', () => {
		expect(typeAheadPath(allRows(), 'cv.typ', 'c')).toBe('blog/chalk-on-the-web.md');
	});

	test('没有光标时从头找', () => {
		expect(typeAheadPath(allRows(), null, 'b')).toBe('blog');
	});

	test('没有匹配：null', () => {
		expect(typeAheadPath(allRows(), 'blog', 'z')).toBeNull();
	});

	test('唯一匹配就是自己：原地不动', () => {
		expect(typeAheadPath(allRows(), 'hacks', 'h')).toBe('hacks');
	});
});
