/**
 * 预览区的缩放状态 —— markdown 的字号倍数与 pdf / typst 的缩放值。
 *
 * 放在模块作用域而不是组件里：换文件会重新挂载视图组件，存组件里一换文件就丢。
 * 生命周期是**一次页面访问**：换文件、切格式都保留，刷新或关掉标签页就复位。
 * 跟上文文件树的展开状态一个口径 —— 纯内存，不落 localStorage，也不上服务端。
 */
const DEFAULT_FONT_SCALE = 1;
const MIN_FONT_SCALE = 0.75;
const MAX_FONT_SCALE = 2;
const FONT_SCALE_STEP = 1.1;

/** 适应容器宽度的模式值。跟 pdf.js 的 `currentScaleValue` 同一个说法。 */
const FIT_WIDTH = 'page-width';

let markdownFontScale = DEFAULT_FONT_SCALE;
let documentScaleValue: number | typeof FIT_WIDTH = FIT_WIDTH;

/** markdown 正文字号的当前倍数。 */
export function readMarkdownFontScale(): number {
	return markdownFontScale;
}

/** markdown 字号放大 / 缩小一档，返回新倍数。 */
export function stepMarkdownFontScale(direction: 'in' | 'out'): number {
	const factor = direction === 'in' ? FONT_SCALE_STEP : 1 / FONT_SCALE_STEP;
	markdownFontScale = Math.min(
		MAX_FONT_SCALE,
		Math.max(MIN_FONT_SCALE, markdownFontScale * factor)
	);
	return markdownFontScale;
}

/** markdown 字号复位成默认倍数（工具栏那个 ↺）。 */
export function resetMarkdownFontScale(): number {
	markdownFontScale = DEFAULT_FONT_SCALE;
	return markdownFontScale;
}

/** 文档视图（pdf / typst）当前的缩放：数字是倍率，`'page-width'` 是适应宽度。 */
export function readDocumentScaleValue(): number | typeof FIT_WIDTH {
	return documentScaleValue;
}

/** 记住用户刚选的文档缩放，供下一个文档复用。 */
export function rememberDocumentScaleValue(value: number | typeof FIT_WIDTH): void {
	documentScaleValue = value;
}
