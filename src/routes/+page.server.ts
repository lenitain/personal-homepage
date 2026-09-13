import type { PageServerLoad } from './$types';
import { CONTENT_DIR } from '$lib/content-dir.server';
import { readContentTree } from '$lib/content-tree';
import { findFileTreeEntry } from '$lib/file-tree';

/** 首屏默认打开的那篇。找不到就留空，让右侧显示空状态。 */
const DEFAULT_DOCUMENT = 'readme.md';

export const load: PageServerLoad = async () => {
	const children = await readContentTree(CONTENT_DIR);
	const tree = {
		path: '',
		name: '~',
		type: 'dir' as const,
		children
	};

	/*
	 * 递归找，不能只看顶层。原先这里是 `children.some(...)`，于是任何嵌套路径的
	 * 默认文档都会被判成「不存在」，首屏直接退化成「select a file to preview」——
	 * 而且失败得毫无提示，看起来像内容没生成出来。
	 */
	const hasDefaultDocument = findFileTreeEntry(tree, DEFAULT_DOCUMENT) !== null;

	return {
		tree,
		initialPath: hasDefaultDocument ? DEFAULT_DOCUMENT : null
	};
};
