/**
 * 预览区的缩放状态 —— markdown 的字号倍数与 pdf / typst 的缩放值。
 *
 * 存在模块作用域 + localStorage：换文件会重新挂载视图组件，只存组件里会丢；
 * 存 localStorage 则连刷新、关掉浏览器再回来都还在。**只在访客自己的浏览器里**，
 * 服务端全程不参与，也不会在访客之间共享 —— 它是「我的偏好」，不是站点配置。
 *
 * 读不到就退回默认值，读到的值一律夹到合法区间：被改坏的存储不能让 pdf.js 收到
 * NaN（它的 currentScale setter 会直接抛 Invalid numeric scale）。
 */
const FONT_SCALE_KEY = 'preview-zoom:markdown-font-scale';
const DOCUMENT_SCALE_KEY = 'preview-zoom:document-scale';

const DEFAULT_FONT_SCALE = 1;
const MIN_FONT_SCALE = 0.75;
const MAX_FONT_SCALE = 2;
const FONT_SCALE_STEP = 1.1;

/** 适应容器宽度的模式值，跟 pdf.js 的 `currentScaleValue` 同一个说法。 */
const FIT_WIDTH = 'page-width';
/** 文档缩放的可接受区间：挡住 NaN、负数、以及被改坏的超大值。 */
const MIN_DOCUMENT_SCALE = 0.1;
const MAX_DOCUMENT_SCALE = 10;

/** 读一条存储。SSR 阶段没有 localStorage、隐私模式下会抛，都当作「没存过」。 */
function readStoredValue(key: string): string | null {
	try {
		return globalThis.localStorage?.getItem(key) ?? null;
	} catch {
		return null;
	}
}

/** 写一条存储。写不进去（隐私模式、配额满）就只留内存，别让缩放把页面搞崩。 */
function writeStoredValue(key: string, value: string): void {
	try {
		globalThis.localStorage?.setItem(key, value);
	} catch {
		// 有意吞掉
	}
}

function loadFontScale(): number {
	const stored = Number.parseFloat(readStoredValue(FONT_SCALE_KEY) ?? '');
	if (!Number.isFinite(stored)) return DEFAULT_FONT_SCALE;
	return Math.min(MAX_FONT_SCALE, Math.max(MIN_FONT_SCALE, stored));
}

function loadDocumentScale(): number | typeof FIT_WIDTH {
	const stored = readStoredValue(DOCUMENT_SCALE_KEY);
	if (stored === FIT_WIDTH) return FIT_WIDTH;

	const scale = Number.parseFloat(stored ?? '');
	if (!Number.isFinite(scale) || scale < MIN_DOCUMENT_SCALE || scale > MAX_DOCUMENT_SCALE) {
		return FIT_WIDTH;
	}
	return scale;
}

let markdownFontScale = loadFontScale();
let documentScaleValue: number | typeof FIT_WIDTH = loadDocumentScale();

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
	writeStoredValue(FONT_SCALE_KEY, String(markdownFontScale));
	return markdownFontScale;
}

/** markdown 字号复位成默认倍数（工具栏那个 ↺）。 */
export function resetMarkdownFontScale(): number {
	markdownFontScale = DEFAULT_FONT_SCALE;
	writeStoredValue(FONT_SCALE_KEY, String(markdownFontScale));
	return markdownFontScale;
}

/** 文档视图（pdf / typst）当前的缩放：数字是倍率，`'page-width'` 是适应宽度。 */
export function readDocumentScaleValue(): number | typeof FIT_WIDTH {
	return documentScaleValue;
}

/** 记住用户刚选的文档缩放，下一个文档、下次打开都用它。 */
export function rememberDocumentScaleValue(value: number | typeof FIT_WIDTH): void {
	documentScaleValue = value;
	writeStoredValue(DOCUMENT_SCALE_KEY, String(value));
}
