import type { FsEntry, TreeRow } from './types';

/**
 * 把文件树拍平成「当前可见」的一行行，供侧边栏渲染和键盘上下移动使用。
 *
 * 只有出现在 expandedPaths 里的目录才会吐出子节点；文件永远当作叶子。
 * 根节点自己不出现在结果里 —— 第一层（根的直接子节点）的 depth 是 0。
 */
export function flattenFileTree(root: FsEntry, expandedPaths: Set<string>): TreeRow[] {
	const rows: TreeRow[] = [];

	function collectChildren(node: FsEntry, depth: number): void {
		if (node.type !== 'dir') return;
		// 根节点总是展开，其余目录要看它是否在展开集合里。
		if (node !== root && !expandedPaths.has(node.path)) return;

		for (const child of node.children ?? []) {
			rows.push({
				entry: child,
				depth,
				expanded: child.type === 'dir' && expandedPaths.has(child.path)
			});
			collectChildren(child, depth + 1);
		}
	}

	collectChildren(root, 0);
	return rows;
}

/** 按「相对 content/ 的路径」在树里查找节点，找不到返回 null。根节点用空串查找。 */
export function findFileTreeEntry(root: FsEntry, path: string): FsEntry | null {
	if (root.path === path) return root;

	for (const child of root.children ?? []) {
		const found = findFileTreeEntry(child, path);
		if (found) return found;
	}

	return null;
}

/** 数出树里一共有多少篇文章。只数文件，目录不计入。 */
export function countFileTreeFiles(root: FsEntry): number {
	if (root.type === 'file') return 1;

	return (root.children ?? []).reduce(
		(total, child) => total + countFileTreeFiles(child),
		0
	);
}
