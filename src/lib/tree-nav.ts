import type { TreeRow } from './types';

/**
 * 文件树的键盘导航 —— 全是纯函数，输入「拍平后的可见行」，输出「意图」，
 * 不碰 DOM、不碰展开集合、不写 URL；副作用都留在 `+page.svelte` 里。
 *
 * 设计出发点是**不用看说明书**：行为对齐用户已经会的东西 —— ↑/↓ 选中即所见
 * （文件管理器的预览），→/← 展开收起（资源管理器 / ARIA 树的标准约定），
 * 首字母跳转（一切文件列表的标配）。
 */

/** PageUp / PageDown 一次跳多少行。树只有几十行，不值得为量视口引入 DOM 测量。 */
export const PAGE_STEP = 10;

/** → 的意图：原地展开一个折叠目录，或走进一个已展开目录的第一个子项。 */
export type ArrowRightIntent = { kind: 'expand'; path: string } | { kind: 'focus'; path: string };

/** ← 的意图：原地收起一个展开的目录，或跳到父目录（父行永远是目录）。 */
export type ArrowLeftIntent = { kind: 'collapse'; path: string } | { kind: 'focus'; path: string };

/** 光标所在行的下标；没有光标、或光标停在已不可见的行上时是 -1。 */
function indexOfPath(rows: TreeRow[], cursorPath: string | null): number {
	return cursorPath === null ? -1 : rows.findIndex((row) => row.entry.path === cursorPath);
}

/**
 * ↑/↓（以及 PageUp/PageDown）的落点：光标行 ± step，越界夹在头尾。
 *
 * 还没有光标时（首屏之外的罕见情况）：第一次移动落到正在读的那篇 ——
 * 让人从「我现在在哪」开始走，而不是从列表顶部重来；正在读的那篇不可见
 * 就落到可见行的头/尾，方向和 step 一致。树是空的返回 null。
 */
export function stepCursorPath(
	rows: TreeRow[],
	cursorPath: string | null,
	openPath: string | null,
	step: number
): string | null {
	if (rows.length === 0) return null;

	const current = indexOfPath(rows, cursorPath);
	if (current === -1) {
		const opened = indexOfPath(rows, openPath);
		const target = opened !== -1 ? opened : step > 0 ? 0 : rows.length - 1;
		return rows[target].entry.path;
	}

	const next = Math.min(Math.max(current + step, 0), rows.length - 1);
	return rows[next].entry.path;
}

/**
 * → 的意图。光标停在文件、空目录、或没有光标时返回 null（原地不动）。
 *
 * 展开一个已展开的目录要靠「下一个可见行是不是它的第一个子项」判断：
 * 拍平是深度优先，子树紧跟在父行后面，所以 `current + 1` 且深度 + 1 就是长子。
 */
export function arrowRight(rows: TreeRow[], cursorPath: string | null): ArrowRightIntent | null {
	const current = indexOfPath(rows, cursorPath);
	if (current === -1) return null;

	const row = rows[current];
	if (row.entry.type !== 'dir') return null;
	if (!row.expanded) return { kind: 'expand', path: row.entry.path };

	const child = rows[current + 1];
	return child && child.depth === row.depth + 1
		? { kind: 'focus', path: child.entry.path }
		: null;
}

/**
 * ← 的意图。展开的目录原地收起；文件和折叠的目录跳到父行。
 * 光标在顶层（深度 0，没有父）或没有光标时返回 null。
 *
 * 父行 = 从光标往回找到的第一个「深度小 1」的行 —— 深度优先拍平保证了
 * 子树和它的父行之间不会隔着别家的祖先，第一个命中就是亲父级。
 */
export function arrowLeft(rows: TreeRow[], cursorPath: string | null): ArrowLeftIntent | null {
	const current = indexOfPath(rows, cursorPath);
	if (current === -1) return null;

	const row = rows[current];
	if (row.entry.type === 'dir' && row.expanded) {
		return { kind: 'collapse', path: row.entry.path };
	}

	for (let i = current - 1; i >= 0; i--) {
		if (rows[i].depth === row.depth - 1) return { kind: 'focus', path: rows[i].entry.path };
	}
	return null;
}

/**
 * 首字母跳转：从光标下一行起找名字以 `ch` 开头（大小写不敏感）的一行，
 * 找到底绕回开头；没有光标就从头找。找不到返回 null。
 *
 * 搜索区间包含光标自己（绕回那一圈的末尾），所以「唯一匹配就是自己」时
 * 返回原地 —— 而重复按同一个字母会自然地在多个匹配之间循环，这正是
 * 文件管理器的行为。不需要额外的「输入缓冲」去支持多字母前缀。
 */
export function typeAheadPath(
	rows: TreeRow[],
	cursorPath: string | null,
	ch: string
): string | null {
	if (rows.length === 0) return null;

	const needle = ch.toLowerCase();
	const current = indexOfPath(rows, cursorPath);

	for (let offset = 1; offset <= rows.length; offset++) {
		// current 为 -1 时 (−1+1) % n = 0，正好从头开始
		const index = (current + offset) % rows.length;
		if (rows[index].entry.name.toLowerCase().startsWith(needle)) {
			return rows[index].entry.path;
		}
	}
	return null;
}
