/** 内容树里的一个节点：一个目录，或一个可预览的文件。 */
export interface FsEntry {
	/** 相对 content/ 的路径，例如 'projects/dotfiles.md'；树的根节点是空串。 */
	path: string;
	name: string;
	type: 'dir' | 'file';
	children?: FsEntry[];
	/**
	 * 可直接显示的正文：
	 * - markdown：源文本，客户端交给 marked 解析
	 * - typst：**已经渲染好的 HTML 片段**，客户端直接插入
	 *
	 * 两者都内联在这里，所以打开任何文档都不需要再发一次请求。
	 * 渲染失败的 typst 没有 content，只有 `error`。
	 */
	content?: string;
	/**
	 * 只有渲染失败的 typst 才有：诊断行（带源位置）。
	 * 单独一个字段而不是把错误塞进 content，是为了让客户端一眼分清
	 * 「一篇正文」和「一次失败」，不用去嗅探内容。
	 */
	error?: string[];	/** 文件字节数（stat.size）。目录没有这个字段。 */
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
