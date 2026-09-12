import type { PageServerLoad } from './$types';
import { CONTENT_DIR } from '$lib/content-dir.server';
import { readContentTree } from '$lib/content-tree';

/** 首屏默认打开的那篇。找不到就留空，让右侧显示空状态。 */
const DEFAULT_DOCUMENT = 'readme.md';

export const load: PageServerLoad = async () => {
	const children = await readContentTree(CONTENT_DIR);
	const hasDefaultDocument = children.some((entry) => entry.path === DEFAULT_DOCUMENT);

	return {
		tree: {
			path: '',
			name: '~',
			type: 'dir' as const,
			children
		},
		initialPath: hasDefaultDocument ? DEFAULT_DOCUMENT : null
	};
};
