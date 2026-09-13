/**
 * 演示模式 —— 把讲义当幻灯片翻。
 *
 * ## 为什么是「模拟」而不是真 PDF
 *
 * 真幻灯片要的是「页」：固定尺寸、一屏一张、能翻。但 typst 的 HTML 导出**没有页这个概念** ——
 * `#set page(...)` 和 `#pagebreak()` 都是二维摆放原语，导出时被直接丢弃
 * （实测会报 `page set rule was ignored during HTML export`，然后所有内容接成一条流）。
 *
 * 拿真 PDF 换「页」的代价是：丢掉按语义元素的粉笔配色（PDF 的文字层只有「文字片段 + 坐标」，
 * 没有「这是标题」，做不到标题一个颜色正文另一个颜色）、Ctrl+F 只能覆盖缓冲区里那十来页、
 * 手机上固定页面尺寸。为了一个演示场景付这些代价不划算。
 *
 * 所以这里的做法是：**内容侧标出「一张幻灯片」的边界，翻页交给 CSS 的 scroll-snap，
 * 键盘导航由这里驱动。** 正文仍然是一份可选中、可搜索、可重排的真文本。
 *
 * ## 状态放哪
 *
 * 模块作用域，且**不落 localStorage**：演示是一个当下正在发生的动作，
 * 不是「我的偏好」。刷新之后回到阅读模式才对 —— 否则你昨天演示到一半关掉，
 * 今天打开一篇文档会莫名其妙全屏。
 */

let presenting = false;

/** 当前是否处于演示模式。 */
export function isPresenting(): boolean {
	return presenting;
}

/** 进入 / 退出演示模式。 */
export function setPresenting(value: boolean): void {
	presenting = value;
}

/**
 * 给定每张幻灯片的顶部偏移量，返回当前视口停在那一张上。
 *
 * 取**最近**而不是「最后一个已滚过的」：scroll-snap 落位之后两者结果一样，
 * 但用户手动滚动、或者容器尺寸变化导致偏移量失效时，「最近」不会突然跳回第一张。
 *
 * 没有幻灯片时返回 -1，调用方据此不显示计数器。
 */
export function nearestSlideIndex(offsets: readonly number[], scrollTop: number): number {
	if (offsets.length === 0) return -1;

	let best = 0;
	let bestDistance = Math.abs(offsets[0] - scrollTop);

	for (let index = 1; index < offsets.length; index++) {
		const distance = Math.abs(offsets[index] - scrollTop);
		if (distance < bestDistance) {
			best = index;
			bestDistance = distance;
		}
	}

	return best;
}

/**
 * 翻页。夹在 `[0, count - 1]` 之间 —— 到头就停住，不循环。
 *
 * 不循环是有意的：讲到最后一张时再按一下，应该什么都不发生，
 * 而不是把听众猛地送回开头。要回开头有 Home 键。
 */
export function stepSlide(current: number, step: number, count: number): number {
	if (count <= 0) return -1;
	const next = current + step;
	return Math.min(count - 1, Math.max(0, next));
}

/**
 * 一张幻灯片的内容大概放不下时，允许它自己滚。
 *
 * 判断依据是「内容比视口高」—— 与其让内容溢出看不见，不如让那一张能滚。
 * 纯函数，输入是高度，便于单测。
 */
export function slideOverflows(contentHeight: number, viewportHeight: number): boolean {
	return contentHeight > viewportHeight + 1; // 1px 容差，避免亚像素误判
}
