<script lang="ts">
	import { onMount } from 'svelte';
	import { marked } from 'marked';
	import DocumentToolbar from './DocumentToolbar.svelte';
	import { readFontScale, resetFontScale, stepFontScale } from '$lib/preview-zoom';
	import type { PreviewKind } from '$lib/preview-kind';

	/**
	 * 右栏唯一的文档视图。
	 *
	 * **两种格式在这里没有区别**：markdown 交给 marked 解析成 HTML，typst 在服务端
	 * 已经渲染成 HTML 片段。到了这一步都只是「一段 HTML 正文」，于是查找、字号、
	 * 粉笔风格、选中行为全都只有一份实现。
	 *
	 * 这正是把 typst 从 pdf 换成 html 的全部意义：以前 pdf 那份要走 canvas + 文字层 +
	 * pdf.js 自己的查找控制器，风格还得靠像素级反色补救；现在它就是正文。
	 */
	let {
		kind,
		source,
		error = null
	}: {
		kind: PreviewKind;
		/** markdown 是源文本；typst 是渲染好的 HTML 片段。 */
		source: string;
		/** 非空表示这篇 typst 渲染失败了，此时显示诊断而不是正文。 */
		error?: string[] | null;
	} = $props();

	let pane = $state<HTMLElement | null>(null);
	let query = $state('');
	let matchLabel = $state('');
	/**
	 * 先按默认字号渲染，挂载后再取存档值。
	 *
	 * 不能直接 `$state(readFontScale())`：SSR 阶段服务端读不到 localStorage、
	 * 客户端水合时读得到，两边算出的 font-size 不一样，Svelte 会报水合不匹配。
	 */
	let fontScale = $state(1);

	onMount(() => {
		fontScale = readFontScale();
	});

	/** typst 的片段是服务端渲染好的，直接用；markdown 现解析。 */
	let html = $derived(kind === 'typst' ? source : (marked.parse(source) as string));

	/** 当前包出来的命中元素，按文档顺序。清空时靠它把 DOM 还原回去。 */
	let hits: HTMLElement[] = [];
	let selectedIndex = -1;

	$effect(() => {
		const value = query;
		// 依赖 pane：挂载后它会从 null 变成元素，effect 因此再跑一次
		if (!pane) return;
		runSearch(value);
	});

	/** 把上次包出来的 `<mark>` 换回纯文本，再把相邻文本节点并回去。 */
	function clearHits() {
		for (const hit of hits) {
			const parent = hit.parentNode;
			if (!parent) continue;
			parent.replaceChild(document.createTextNode(hit.textContent ?? ''), hit);
			parent.normalize();
		}
		hits = [];
		selectedIndex = -1;
	}

	function runSearch(value: string) {
		clearHits();

		const article = pane?.querySelector('article');
		if (!article || !value) {
			matchLabel = '';
			return;
		}

		const needle = value.toLowerCase();
		const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
		const textNodes: Text[] = [];
		while (walker.nextNode()) {
			const node = walker.currentNode as Text;
			if (node.nodeValue?.toLowerCase().includes(needle)) textNodes.push(node);
		}

		// 先把候选节点收集齐再动 DOM —— 边遍历边改会让 walker 失效
		for (const textNode of textNodes) {
			const text = textNode.nodeValue ?? '';
			const lowered = text.toLowerCase();
			const fragment = document.createDocumentFragment();
			let cursor = 0;
			let at = lowered.indexOf(needle);

			while (at !== -1) {
				if (at > cursor) fragment.append(text.slice(cursor, at));
				const mark = document.createElement('mark');
				mark.className = 'find-hit';
				mark.textContent = text.slice(at, at + value.length);
				fragment.append(mark);
				hits.push(mark);
				cursor = at + value.length;
				at = lowered.indexOf(needle, cursor);
			}

			if (cursor === 0) continue;
			if (cursor < text.length) fragment.append(text.slice(cursor));
			textNode.parentNode?.replaceChild(fragment, textNode);
		}

		if (hits.length === 0) {
			matchLabel = '0 / 0';
			return;
		}

		selectHit(0);
	}

	function selectHit(index: number) {
		for (const hit of hits) hit.classList.remove('selected');
		selectedIndex = index;
		const current = hits[index];
		current.classList.add('selected');
		current.scrollIntoView({ block: 'center' });
		matchLabel = `${index + 1} / ${hits.length}`;
	}

	function find(direction: 'next' | 'previous') {
		if (hits.length === 0) return;
		const step = direction === 'next' ? 1 : -1;
		selectHit((selectedIndex + step + hits.length) % hits.length);
	}

	function zoom(direction: 'in' | 'out' | 'fit') {
		fontScale = direction === 'fit' ? resetFontScale() : stepFontScale(direction);
	}
</script>

{#if error}
	<div class="failure">
		<p>{kind} 渲染失败</p>
		<pre>{error.join('\n')}</pre>
	</div>
{:else}
	<DocumentToolbar bind:query {matchLabel} onFind={find} onZoom={zoom} />

	<div class="document-scroll" bind:this={pane}>
		<article style="font-size: {fontScale}em">{@html html}</article>
	</div>
{/if}

<style>
	.failure {
		padding: 0.8em;
		color: var(--red);
	}

	.failure pre {
		margin-top: 0.4em;
		white-space: pre-wrap;
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
		font-size: 0.9em;
		color: var(--orange);
	}

	.document-scroll {
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		background: var(--bg0);
		padding: 0 0.8em;
	}

	/*
	 * 粉笔抖动只套在正文上。原先套在整栏（见 +page.svelte），滚动区一大就会拖垮
	 * 重栅格化，所以按内容类型各自套 —— 现在只有这一处，因为只剩这一种正文。
	 */
	article {
		filter: url(#chalk-writing);
	}

	/* 命中的词：底部半透明，当前那个用实色反白，滚动时一眼能找到 */
	article :global(.find-hit) {
		background: color-mix(in srgb, var(--yellow) 32%, transparent);
		color: inherit;
	}

	article :global(.find-hit.selected) {
		background: var(--orange);
		color: var(--bg0);
	}

	/* ---- 正文排版：两种格式共用 ---- */

	article :global(h1) {
		color: var(--green);
		font-size: 1.3em;
		margin: 0.8em 0 0.4em;
		border-bottom: 1px solid var(--bg4);
		padding-bottom: 0.2em;
	}

	article :global(h2) {
		color: var(--aqua);
		font-size: 1.15em;
		margin: 0.7em 0 0.3em;
	}

	article :global(h3) {
		color: var(--yellow);
		font-size: 1.05em;
		margin: 0.5em 0 0.2em;
	}

	article :global(p) {
		color: var(--fg);
		margin: 0.4em 0;
		line-height: 1.6;
	}

	article :global(strong) {
		color: var(--orange);
	}

	article :global(em) {
		color: var(--purple);
	}

	article :global(a) {
		color: var(--blue);
		text-decoration: underline;
	}

	article :global(code) {
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
		background: var(--bg2);
		color: var(--red);
		padding: 0.1em 0.35em;
		border-radius: 2px;
		font-size: 0.9em;
	}

	article :global(pre) {
		background: var(--bg2);
		border: 1px solid var(--bg4);
		padding: 0.8em;
		margin: 0.5em 0;
		overflow-x: auto;
	}

	article :global(pre code) {
		background: none;
		padding: 0;
		color: var(--fg);
	}

	article :global(ul),
	article :global(ol) {
		margin: 0.3em 0;
		padding-left: 1.5em;
		color: var(--fg);
	}

	article :global(li) {
		margin: 0.15em 0;
	}

	article :global(li::marker) {
		color: var(--grey1);
	}

	article :global(blockquote) {
		border-left: 3px solid var(--grey1);
		margin: 0.5em 0;
		padding: 0.2em 0.8em;
		color: var(--grey2);
		background: var(--bg1);
	}

	/*
	 * 分隔线。两种格式都给 `<hr>`：markdown 的 `---`，typst 的 `#divider()`
	 * （0.15 新增的语义元素，HTML 目标下正是 `<hr>`）。所以一条规则管两处 ——
	 * 不需要再为 typst 单独造一个带 class 的画线 helper。
	 */
	article :global(hr) {
		border: none;
		border-top: 1px solid var(--bg4);
		margin: 0.8em 0;
	}

	article :global(table) {
		border-collapse: collapse;
		margin: 0.5em 0;
		width: 100%;
	}

	article :global(th),
	article :global(td) {
		border: 1px solid var(--bg4);
		padding: 0.3em 0.6em;
		text-align: left;
	}

	article :global(th) {
		background: var(--bg2);
		color: var(--yellow);
	}

	article :global(img) {
		max-width: 100%;
		height: auto;
	}

	/* ---- typst 专用：内容侧交出的结构，样式在这里定 ---- */

	/* `#site-columns` 在 HTML 目标下就是这个词：两栏归样式表管。 */
	article :global(.cv-columns) {
		display: grid;
		grid-template-columns: 1fr 2.4fr;
		gap: 1.2em;
		align-items: start;
		margin-bottom: 1em;
	}

	/* `#site-name` / `#site-subtitle`：语义是 h1 + p，外观在这里给。 */
	article :global(.cv-name) {
		margin: 0;
		border: none;
		padding: 0;
		font-size: 1.6em;
	}

	article :global(.cv-subtitle) {
		margin: 0.2em 0 0;
		font-style: italic;
		color: var(--grey2);
	}


	/* 窄屏下两栏并排放不下，摊成一栏 */
	@media (max-width: 640px) {
		article :global(.cv-columns) {
			grid-template-columns: 1fr;
		}
	}
</style>
