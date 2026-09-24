import { describe, expect, test } from 'vitest';
import {
	MOVE_HISTORY_WINDOW_MS,
	browseStateOf,
	browseStateToSearch,
	directoryAncestors,
	parseBrowseState,
	resolveBrowseState,
	shouldCreateHistoryEntry
} from './browse-state';
import type { FsEntry } from './types';

function markdownFile(name: string, path: string): FsEntry {
	return { path, name, type: 'file', content: `# ${name}\n` };
}

function directory(name: string, path: string, children: FsEntry[]): FsEntry {
	return { path, name, type: 'dir', children };
}

/** 跟 content/ 同构：一层混合目录 + 一个嵌套两层的课件目录。 */
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
		markdownFile('readme.md', 'readme.md')
	]);
}

describe('parseBrowseState', () => {
	test('空的 search 解析成「什么都没说」', () => {
		expect(parseBrowseState('')).toEqual({ file: null, dirs: [] });
		expect(parseBrowseState('?')).toEqual({ file: null, dirs: [] });
	});

	test('读出 file 和一个 dirs', () => {
		expect(parseBrowseState('?file=blog/why-yazi.md&dirs=projects')).toEqual({
			file: 'blog/why-yazi.md',
			dirs: ['projects']
		});
	});

	test('dirs 可以重复出现，结果去重且有序', () => {
		expect(parseBrowseState('?dirs=projects&dirs=blog&dirs=projects').dirs).toEqual([
			'blog',
			'projects'
		]);
	});

	test('空值当没写，不留空字符串', () => {
		expect(parseBrowseState('?file=&dirs=')).toEqual({ file: null, dirs: [] });
	});

	test('不认识的参数直接忽略', () => {
		expect(parseBrowseState('?utm_source=x&file=readme.md')).toEqual({
			file: 'readme.md',
			dirs: []
		});
	});

	test('百分号编码的路径被还原', () => {
		expect(parseBrowseState('?file=blog/%E4%B8%BA%E4%BB%80%E4%B9%88.md').file).toBe(
			'blog/为什么.md'
		);
	});
});

describe('browseStateToSearch', () => {
	test('空状态编码成空串 —— 地址栏保持干净的 /', () => {
		expect(browseStateToSearch({ file: null, dirs: [] })).toBe('');
	});

	test('编码结果带前导问号，路径里的斜杠保持可读，dirs 每个一个参数', () => {
		expect(browseStateToSearch({ file: 'blog/why-yazi.md', dirs: ['projects'] })).toBe(
			'?file=blog/why-yazi.md&dirs=projects'
		);
	});

	test('文件名里本来就有的 %2F 字样不会被误解码', () => {
		const search = browseStateToSearch({ file: 'blog/a%2Fb.md', dirs: [] });

		expect(search).toBe('?file=blog/a%252Fb.md');
		expect(parseBrowseState(search).file).toBe('blog/a%2Fb.md');
	});

	test('没有 file 时只有 dirs', () => {
		expect(browseStateToSearch({ file: null, dirs: ['blog'] })).toBe('?dirs=blog');
	});

	test('非 ASCII 路径写出去再读回来不变', () => {
		const state = { file: 'blog/为什么.md', dirs: ['教程 一'] };

		expect(parseBrowseState(browseStateToSearch(state))).toEqual({
			file: 'blog/为什么.md',
			dirs: ['教程 一']
		});
	});
});

describe('directoryAncestors', () => {
	test('顶层文件没有祖先', () => {
		expect(directoryAncestors('readme.md')).toEqual([]);
	});

	test('多层路径逐级列出，且不含自己', () => {
		expect(directoryAncestors('hacks/resident-browser/index.typ')).toEqual([
			'hacks',
			'hacks/resident-browser'
		]);
	});
});

describe('browseStateOf', () => {
	test('属于当前文件祖先的展开目录不写进 URL', () => {
		expect(browseStateOf('blog/why-yazi.md', ['blog', 'projects'])).toEqual({
			file: 'blog/why-yazi.md',
			dirs: ['projects']
		});
	});

	test('没打开文件时，展开目录全部算额外展开', () => {
		expect(browseStateOf(null, ['blog'])).toEqual({ file: null, dirs: ['blog'] });
	});

	test('dirs 输出有序，跟传入顺序无关', () => {
		expect(browseStateOf('readme.md', ['projects', 'blog']).dirs).toEqual(['blog', 'projects']);
	});
});

describe('resolveBrowseState', () => {
	test('树里存在的文件被接受', () => {
		const resolved = resolveBrowseState(sampleTree(), { file: 'blog/why-yazi.md', dirs: [] });

		expect(resolved.file).toBe('blog/why-yazi.md');
	});

	test('不存在的文件退回 null', () => {
		const resolved = resolveBrowseState(sampleTree(), { file: 'blog/missing.md', dirs: [] });

		expect(resolved.file).toBeNull();
		expect(resolved.expanded).toEqual([]);
	});

	test('指向目录的 file 也算无效', () => {
		expect(resolveBrowseState(sampleTree(), { file: 'blog', dirs: [] }).file).toBeNull();
	});

	test('补上当前文件的祖先，让它在树里看得见', () => {
		const resolved = resolveBrowseState(sampleTree(), {
			file: 'hacks/resident-browser/index.typ',
			dirs: []
		});

		expect(resolved.expanded).toEqual(['hacks', 'hacks/resident-browser']);
	});

	test('dirs 里不是目录的条目丢掉', () => {
		const resolved = resolveBrowseState(sampleTree(), {
			file: null,
			dirs: ['blog', 'readme.md', 'nope', 'blog/why-yazi.md']
		});

		expect(resolved.expanded).toEqual(['blog']);
	});

	test('展开集合去重且有序', () => {
		const resolved = resolveBrowseState(sampleTree(), { file: null, dirs: ['blog', 'blog'] });

		expect(resolved.expanded).toEqual(['blog']);
	});

	test('没有 file 时只保留 dirs', () => {
		expect(resolveBrowseState(sampleTree(), { file: null, dirs: ['hacks'] })).toEqual({
			file: null,
			expanded: ['hacks']
		});
	});
});

describe('往返', () => {
	test('写出去再读回来，打开的文档和展开集合都不变', () => {
		const tree = sampleTree();
		const expanded = ['blog', 'hacks', 'hacks/resident-browser'];
		const state = browseStateOf('hacks/resident-browser/index.typ', expanded);

		const restored = resolveBrowseState(tree, parseBrowseState(browseStateToSearch(state)));

		expect(restored.file).toBe('hacks/resident-browser/index.typ');
		expect(restored.expanded).toEqual(expanded);
	});

	test('写出去再读回来，只有 dirs 没有 file 时也稳定', () => {
		const tree = sampleTree();
		const state = browseStateOf(null, ['blog', 'hacks']);

		const restored = resolveBrowseState(tree, parseBrowseState(browseStateToSearch(state)));

		expect(restored.file).toBeNull();
		expect(restored.expanded).toEqual(['blog', 'hacks']);
	});

	test('编码是稳定的：同一个状态两次编码结果一样', () => {
		const state = browseStateOf('blog/why-yazi.md', ['projects', 'blog']);

		expect(browseStateToSearch(state)).toBe(browseStateToSearch(state));
	});
});

describe('shouldCreateHistoryEntry', () => {
	const now = 10_000;

	test('确认打开（点击 / Enter）永远新开一条', () => {
		expect(shouldCreateHistoryEntry('push', now, now - 1)).toBe(true);
		expect(shouldCreateHistoryEntry('push', now, now)).toBe(true);
	});

	test('视图偏好（开合目录）从不新开', () => {
		expect(shouldCreateHistoryEntry('replace', now, now - 1)).toBe(false);
		expect(shouldCreateHistoryEntry('replace', now, 0)).toBe(false);
	});

	test('浏览移动：距上次新开不足一个窗口 → 并进上一条', () => {
		expect(shouldCreateHistoryEntry('move', now, now - MOVE_HISTORY_WINDOW_MS + 1)).toBe(false);
		expect(shouldCreateHistoryEntry('move', now, now - 1)).toBe(false);
	});

	test('浏览移动：停够一个窗口 → 新开一条', () => {
		expect(shouldCreateHistoryEntry('move', now, now - MOVE_HISTORY_WINDOW_MS)).toBe(true);
		// lastPushAt = 0 表示「还没推送过」；真实时钟的 Date.now() 远大于窗口，
		// 所以加载后的第一次移动必然新开一条，把落地页留在历史里。
		expect(shouldCreateHistoryEntry('move', now, 0)).toBe(true);
	});
});
