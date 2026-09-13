import type { PageServerLoad } from './$types';
import { CONTENT_DIR } from '$lib/content-dir.server';
import { readContentTree } from '$lib/content-tree';
import { findFileTreeEntry } from '$lib/file-tree';
import { parseBrowseState, resolveBrowseState } from '$lib/browse-state';

/** URL 里没指名文档时打开的那篇。找不到就留空，让右侧显示空状态。 */
const DEFAULT_DOCUMENT = 'readme.md';

/**
 * 首屏的浏览位置来自地址栏 —— 这是「刷新之后还是上次那篇」的全部机制。
 *
 * 服务端读得到 URL，所以刷新出来的第一帧就是那篇文章，不用等客户端挂载后再跳一次。
 * 解析与校验都在 `browse-state.ts` 里（纯函数、有单测），这里只做三件事：读树、
 * 解析 URL、把默认文档按树校验一遍。
 */
export const load: PageServerLoad = async ({ url }) => {
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
	const defaultEntry = findFileTreeEntry(tree, DEFAULT_DOCUMENT);

	/* URL 是外部输入：不认识的一律丢掉，指向已删除内容的旧链接回落默认文档。 */
	const requested = parseBrowseState(url.search);
	const restored = resolveBrowseState(tree, requested);

	return {
		tree,
		defaultPath: defaultEntry?.type === 'file' ? defaultEntry.path : null,
		/*
		 * 和 defaultPath 分开两个字段，而不是合成一个「首屏打开哪篇」：客户端要区分
		 * 「地址栏什么都没说」和「地址栏指名了一篇但已失效」。只有分开，后退到一个不带
		 * file 的历史记录时，行为才和直接访问那个地址完全一致。
		 */
		restoredFile: restored.file,
		/* 刷新前开着的文件夹，刷新后还是开着的（已补上 restoredFile 的祖先）。 */
		initialExpanded: restored.expanded
	};
};
