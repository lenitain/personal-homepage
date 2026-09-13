/**
 * 焦点是不是落在一个「该收键盘输入」的地方。
 *
 * 全局快捷键（文件树的 ↑/↓/Enter、演示模式的翻页）都要先问一遍这个 ——
 * 否则在搜索框里打字的后果是：文件树的光标在动、Enter 顺手打开一篇文件、
 * 或者幻灯片突然翻页。
 *
 * 抽成独立模块是因为它有两个调用方（`+page.svelte` 的文件树导航、
 * `DocumentView` 的演示翻页），而两边必须给出**完全一致**的判断 ——
 * 任何一边漏掉一种输入控件，就会出现「在某处打字会触发快捷键」的怪 bug。
 *
 * 用 `instanceof HTMLElement` 挡掉非元素目标（`document`、`window` 等）。
 */
export function isTextEntryTarget(target: EventTarget | null): boolean {
	if (!(target instanceof HTMLElement)) return false;
	if (target.isContentEditable) return true;
	return ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName);
}
