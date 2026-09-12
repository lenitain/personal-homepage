/** 右栏拿什么渲染器显示一个文件。 */
export type PreviewKind = 'markdown' | 'typst' | 'pdf';

/**
 * 预览类型判定 —— 按文件名的扩展名决定右栏用哪个渲染器。
 *
 * 服务端拿它过滤文件树、客户端拿它分派渲染器，两端共用同一个函数，
 * 于是不会出现「树里有、点开不认识」的错配。扩展名比较不看大小写，
 * 多点文件名（`cv.v2.typ`）取最后一个点之后的部分。
 */
export function previewKindOf(name: string): PreviewKind | null {
	const dot = name.lastIndexOf('.');
	if (dot === -1) return null;

	switch (name.slice(dot).toLowerCase()) {
		case '.md':
			return 'markdown';
		case '.typ':
			return 'typst';
		case '.pdf':
			return 'pdf';
		default:
			return null;
	}
}
