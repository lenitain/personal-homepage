/** 内容树里的一个节点：一个目录，或一个可预览的文件。 */
export interface FsEntry {
	/** 相对 content/ 的路径，例如 'projects/dotfiles.md'；树的根节点是空串。 */
	path: string;
	name: string;
	type: 'dir' | 'file';
	children?: FsEntry[];
	/** 只有 markdown 内联正文；typst 与 pdf 的内容走各自的 HTTP 路由，这里留空。 */
	content?: string;
	/** 文件字节数（stat.size）。目录没有这个字段。 */
	size?: number;
	mtime?: string;
}

/** 文件树被拍平成一维之后的一行，侧边栏按数组顺序从上往下渲染。 */
export interface TreeRow {
	entry: FsEntry;
	/** 0 表示根的直接子节点。 */
	depth: number;
	/** 只对目录有意义：文件永远是 false。 */
	expanded: boolean;
}
