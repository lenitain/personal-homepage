/**
 * markdown 正文字号的缩放倍数。
 *
 * 放在模块作用域而不是组件里：换文件会重新挂载组件，存在组件里会跳回默认值。
 * 只活在内存里（刷新即复位），跟文件树展开状态的处理保持一致。
 */
const DEFAULT_SCALE = 1;
const MIN_SCALE = 0.75;
const MAX_SCALE = 2;
const STEP = 1.1;

let currentScale = DEFAULT_SCALE;

/** 读当前倍数。 */
export function readMarkdownFontScale(): number {
	return currentScale;
}

/** 放大 / 缩小一档，返回新倍数。 */
export function stepMarkdownFontScale(direction: 'in' | 'out'): number {
	const factor = direction === 'in' ? STEP : 1 / STEP;
	currentScale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, currentScale * factor));
	return currentScale;
}

/** 复位成默认倍数（工具栏那个 ↺ 按钮）。 */
export function resetMarkdownFontScale(): number {
	currentScale = DEFAULT_SCALE;
	return currentScale;
}
