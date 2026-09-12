/**
 * 黑板粉笔的调色板 —— 服务端与客户端共用的那一份。
 *
 * 跟 `src/routes/+layout.svelte` 里的 CSS 变量一一对应，但那边是给 CSS 用的、
 * 这边是给「读不到 CSS 的代码」用的：typst 编译时要把颜色写进 wrapper，
 * pdf 反色时要把页底抬到板色。改主题色要同时改这里和 layout（见 spec 的「风险」）。
 */
export const CHALK_PALETTE = {
	/** `--bg0`：黑板底色。 */
	board: '#2D353B',
	/** `--fg`：粉笔正文色。 */
	ink: '#D3C6AA',
	/** `--blue`：链接。 */
	link: '#7FBBB3',
	/** `--red`：行内代码。 */
	code: '#E67E80'
} as const;
