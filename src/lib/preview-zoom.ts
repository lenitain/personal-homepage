/**
 * 预览区的字号倍数 —— 正文（markdown 与 typst）共用的那一个「放大 / 缩小」。
 *
 * 只有字号这一种缩放：两种格式的正文都是真 DOM 文本，所以它们的缩放语义完全一样。
 * （曾经还有一套给 pdf 用的倍率／适应宽度，那是画布才需要的概念，随 pdf 一起没了。）
 *
 * 存在模块作用域 + localStorage：换文件会重新挂载视图组件，只存组件里会丢；
 * 存 localStorage 则连刷新、关掉浏览器再回来都还在。**只在访客自己的浏览器里**，
 * 服务端全程不参与，也不会在访客之间共享 —— 它是「我的偏好」，不是站点配置。
 *
 * 读不到就退回默认值，读到的值一律夹到合法区间：被改坏的存储不能让字号变成 NaN。
 */
const FONT_SCALE_KEY = 'preview-zoom:font-scale';

const DEFAULT_FONT_SCALE = 1;
const MIN_FONT_SCALE = 0.75;
const MAX_FONT_SCALE = 2;
const FONT_SCALE_STEP = 1.1;

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

let fontScale = loadFontScale();

/** 正文字号的当前倍数。 */
export function readFontScale(): number {
	return fontScale;
}

/** 正文字号放大 / 缩小一档，返回新倍数。 */
export function stepFontScale(direction: 'in' | 'out'): number {
	const factor = direction === 'in' ? FONT_SCALE_STEP : 1 / FONT_SCALE_STEP;
	fontScale = Math.min(MAX_FONT_SCALE, Math.max(MIN_FONT_SCALE, fontScale * factor));
	writeStoredValue(FONT_SCALE_KEY, String(fontScale));
	return fontScale;
}

/** 正文字号复位成默认倍数（工具栏那个 ↺）。 */
export function resetFontScale(): number {
	fontScale = DEFAULT_FONT_SCALE;
	writeStoredValue(FONT_SCALE_KEY, String(fontScale));
	return fontScale;
}
