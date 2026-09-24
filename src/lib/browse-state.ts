import { findFileTreeEntry } from './file-tree';
import type { FsEntry } from './types';

/**
 * 浏览位置 —— 「上次看到哪」，存在 URL 里。
 *
 * ## 为什么是 URL
 *
 * 右栏打开哪篇、左栏展开哪些目录，是这个站唯一值得跨刷新记住的东西。放 URL 而不是
 * localStorage 只有一个理由，但它是决定性的：**服务端读得到**。正文本来就随 SSR 载荷
 * 整体内联，所以 `load` 拿到 `?file=` 之后，刷新出来的第一帧就是那篇文章 —— 不存在
 * 「先渲染默认文档、等 JS 挂载之后再跳过去」的那一闪。顺带白赚：可收藏、可分享、
 * 后退键能回到上一篇。
 *
 * 对照 `preview-zoom.ts`：字号是「我的偏好」，所以它在 localStorage；而「正在看哪篇」
 * 是一个可以被指给别人看的位置，所以它在 URL。
 *
 * ## URL 的形状
 *
 * ```
 * /?file=blog/why-yazi.md                  ← 常见情况就这么短
 * /?file=hacks/resident-browser/index.typ&dirs=projects
 * ```
 *
 * `dirs` 用**重复参数**而不是逗号分隔：目录名里可能有逗号，重复参数不需要转义。
 * `dirs` 里**不记当前文件的祖先** —— 那一段能从 `file` 推出来（`directoryAncestors`），
 * 读取时再补回去。于是「只开着一个文件夹」这种最常见的情形不会在 URL 里重复一遍路径。
 *
 * 代价是一个已知例外：把当前文档所在的文件夹手动收起来，那个状态刷新后会变回展开
 * （因为祖先总会在读取时被补回）。反过来做（把祖先也写进 URL）只能换来一个「文档在
 * 树里隐身」的自洽状态，不值。
 *
 * ## 这个模块里全是纯函数
 *
 * 解析、编码、按树校验、推祖先都不碰 DOM、不碰 history，所以能直接单测；改地址栏那步
 * 留在 `+page.svelte` 里。URL 是外部输入（几个月前的书签、别人手改过的链接），所以
 * 校验一律「不认识就丢」，绝不抛错。唯一不碰 URL 本身的是 {@link shouldCreateHistoryEntry}
 * —— 它只回答「这次该新开历史记录还是并进上一条」，同样是纯函数。
 */

/** URL 里那两个参数名。改这里就是改地址栏的形状。 */
const FILE_PARAM = 'file';
const DIRS_PARAM = 'dirs';

export type HistoryWrite = 'push' | 'replace' | 'move';

/**
 * ↑/↓ 连续浏览时，两次新开历史记录之间至少隔多久（毫秒）。
 * 见 {@link shouldCreateHistoryEntry}。
 */
export const MOVE_HISTORY_WINDOW_MS = 1000;

/**
 * 这次写地址栏，要不要往浏览器历史里**新开**一条（false = 并进当前这条，replace）。
 *
 * - `'push'`：确认打开（点击 / Enter）。明确去了一个地方，永远新开，后退键
 *   才能回到上一篇；
 * - `'replace'`：开合目录这类视图偏好，从不新开（理由见模块注释）；
 * - `'move'`：↑/↓「选中即打开」的连续浏览。按住方向键会走出十几步，每步都
 *   push 会让后退键变成按步数收费；距上次新开不足 `MOVE_HISTORY_WINDOW_MS`
 *   就并进上一条 —— 「在一个地方停留够久 = 一次到访」。
 *
 * `lastPushAt = 0` 表示还没推送过：真实时钟的 `Date.now()` 远大于窗口，
 * 所以加载后的第一次移动必然新开一条，落地页不会被吞掉。
 */
export function shouldCreateHistoryEntry(
	write: HistoryWrite,
	now: number,
	lastPushAt: number
): boolean {
	if (write === 'push') return true;
	if (write === 'replace') return false;
	return now - lastPushAt >= MOVE_HISTORY_WINDOW_MS;
}

/** URL 里记着的浏览位置。 */
export interface BrowseState {
	/** 右栏要打开的文档（相对 content/ 的路径）；null 表示 URL 什么都没说。 */
	file: string | null;
	/** 额外展开的目录，**不含** `file` 的祖先 —— 那些由 `directoryAncestors` 推出来。 */
	dirs: string[];
}

/** 按树校验之后的浏览位置，可以直接喂给页面。 */
export interface ResolvedBrowseState {
	/** 校验过的文档路径；URL 没写、或写的是树里没有的路径时是 null。 */
	file: string | null;
	/** 首屏该展开的目录，已补上 `file` 的祖先；有序，可直接构造 Set。 */
	expanded: string[];
}

/** 解析 `location.search`，得到 URL 里记着的浏览位置。 */
export function parseBrowseState(search: string): BrowseState {
	const params = new URLSearchParams(search);
	const file = params.get(FILE_PARAM);

	return {
		file: file ? file : null,
		dirs: sortedUniquePaths(params.getAll(DIRS_PARAM))
	};
}

/**
 * 把浏览位置编码回 `location.search`（带前导 `?`）。
 *
 * 什么都没有时返回空串，让地址栏保持干净的 `/`。斜杠会从 `%2F` 换回 `/` —— 这个地址
 * 是要给人看、给人分享的，而查询串里出现裸斜杠完全合法，`URLSearchParams` 读回来一样。
 * 只动 `%2F` 这三个字符：文件名里真有一个 `%2F` 字样时，它编出来是 `%252F`，不受影响。
 */
export function browseStateToSearch(state: BrowseState): string {
	const params = new URLSearchParams();
	if (state.file) params.set(FILE_PARAM, state.file);
	for (const dir of state.dirs) params.append(DIRS_PARAM, dir);

	const search = params.toString();
	return search ? `?${search.replace(/%2F/g, '/')}` : '';
}

/**
 * 一个文件路径上逐级的目录：`a/b/c.md` → `['a', 'a/b']`，顶层文件 → `[]`。
 *
 * 不含文件自己，也就是「要让它出现在树里，必须展开的那些目录」。
 */
export function directoryAncestors(path: string): string[] {
	const segments = path.split('/');
	const ancestors: string[] = [];

	for (let depth = 1; depth < segments.length; depth++) {
		ancestors.push(segments.slice(0, depth).join('/'));
	}

	return ancestors;
}

/** 由「打开的文件 + 展开集合」算出该写进 URL 的状态：祖先从 `dirs` 里减掉。 */
export function browseStateOf(file: string | null, expandedPaths: Iterable<string>): BrowseState {
	const ancestors = new Set(file ? directoryAncestors(file) : []);

	return {
		file,
		dirs: sortedUniquePaths([...expandedPaths].filter((path) => !ancestors.has(path)))
	};
}

/**
 * 按树校验 URL 里的浏览位置：`file` 必须是树里真实存在的**文件**（指向目录也算无效），
 * `dirs` 里不是**目录**的一律丢掉，最后补上 `file` 的祖先。
 *
 * 内容改名、删掉之后，旧链接会把 `file` 归成 null，调用方据此回落默认文档 —— 坏链接的
 * 正确表现是「打开首页」，不是「打开错误页」。
 */
export function resolveBrowseState(root: FsEntry, state: BrowseState): ResolvedBrowseState {
	const file = resolveBrowsableFile(root, state.file);
	const expanded = new Set<string>(file ? directoryAncestors(file) : []);

	for (const dir of state.dirs) {
		if (isDirectoryInTree(root, dir)) expanded.add(dir);
	}

	return { file, expanded: [...expanded].sort() };
}

function resolveBrowsableFile(root: FsEntry, file: string | null): string | null {
	if (!file) return null;

	const entry = findFileTreeEntry(root, file);
	return entry?.type === 'file' ? entry.path : null;
}

/** 根节点（空串）永远展开，不靠这个集合表达，所以在这里挡掉。 */
function isDirectoryInTree(root: FsEntry, path: string): boolean {
	if (!path) return false;
	return findFileTreeEntry(root, path)?.type === 'dir';
}

/**
 * 去重 + 排序 + 丢掉空串。
 *
 * 用默认的 `.sort()`（按 UTF-16 码元）而不是 `localeCompare`：后者依赖运行环境的 ICU
 * 数据，同一个状态在 Node 与浏览器里可能排出不同顺序，URL 就不再稳定。
 */
function sortedUniquePaths(paths: readonly string[]): string[] {
	return [...new Set(paths.filter((path) => path !== ''))].sort();
}
