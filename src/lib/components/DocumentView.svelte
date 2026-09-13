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

	/*
	 * typst 的 HTML 导出把 `=` 映射到 `<h2>`、`==` 到 `<h3>`、`===` 到 `<h4>`
	 * —— 它给文档标题留了 h1。所以四级标题是真实会出现的，不能没有规则，
	 * 否则掉回浏览器默认（粗体、同字号），在手写体滤镜下看着像漏排。
	 */
	article :global(h4) {
		color: var(--purple);
		font-size: 1em;
		margin: 0.4em 0 0.15em;
	}

	/*
	 * 术语表。typst 的 `/ 术语: 解释` 交出 `<dl><dt><dd>`，而浏览器默认把 dt 和 dd
	 * 排成两行普通文字 —— 名字和解释分不出来。课件里用它列「脚本 → 干什么」，
	 * 所以术语要跟正文区分开、解释要缩进。
	 */
	article :global(dl) {
		margin: 0.4em 0;
	}

	article :global(dt) {
		color: var(--aqua);
		margin-top: 0.4em;
	}

	article :global(dd) {
		margin: 0.1em 0 0 1.2em;
		line-height: 1.6;
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


	/* ---- 课件版式：typst 交出结构，这里定长相与摆放 ---- */

	/*
	 * 这套规则的存在理由：typst 的 HTML 导出丢掉一切二维摆放，所以版面只能在
	 * CSS 这一层做。反过来说，能做到的事一点不少 —— 内容侧用 `html.elem` 交出
	 * 带 class 的结构（见 content/hacks/resident-browser/.course.typ），
	 * 网格、分栏、重量差异全在这里实现。
	 *
	 * 按**重量**分档，而不是按颜色分类：提问比正文重、实验是中性的记录、
	 * 结论落地、旁注比正文还轻。全是同等重量的彩色框会让读者去收集框而不是读内容。
	 */

	article :global(.c-box) {
		background: var(--bg1);
		border: 1px solid var(--bg4);
		border-left-width: 3px;
		padding: 0.6em 0.9em;
		margin: 1em 0;
		/* 框里的文字不一定经过 <p>，行高在这里补，否则比正文挤 */
		line-height: 1.6;
	}

	article :global(.c-label) {
		color: var(--grey2);
		font-size: 0.82em;
		letter-spacing: 0.08em;
		margin: 0 0 0.4em;
	}

	/* 首个段落不再叠外边距，否则框内上头会空一块 */
	article :global(.c-box > p) {
		margin: 0;
	}

	/* 框内的后续块之间给点呼吸，但不撑开 */
	article :global(.c-box > p + p),
	article :global(.c-box > pre),
	article :global(.c-box > ul),
	article :global(.c-box > ol),
	article :global(.c-box > table),
	article :global(.c-box > .c-cols),
	article :global(.c-box > .c-box) {
		margin-top: 0.5em;
	}

	/* 提问：底色压暗一档，让它从正文里跳出来，但不带攻击性 */
	article :global(.c-ask) {
		background: var(--bg0);
		border-left-color: var(--aqua);
	}

	article :global(.c-ask .c-label) {
		color: var(--aqua);
	}

	/* 实验记录：中性的容器，重点是里面的原始输出 */
	article :global(.c-lab) {
		border-left-color: var(--yellow);
	}

	article :global(.c-lab .c-label) {
		color: var(--yellow);
	}

	/* 实验框里的代码块是第二层框，压平一点免得嵌套太吵 */
	article :global(.c-lab pre) {
		background: var(--bg0);
		border-color: var(--bg4);
	}

	/* 被推翻的判断：红色，但只有左边那条 */
	article :global(.c-oops) {
		border-left-color: var(--red);
	}

	article :global(.c-oops .c-label) {
		color: var(--red);
	}

	/* 旁注：比正文还轻，可以跳过 */
	article :global(.c-note) {
		background: none;
		border: none;
		border-left: 2px dotted var(--grey1);
		border-radius: 0;
		color: var(--grey2);
		font-size: 0.95em;
		margin: 0.9em 0;
	}

	article :global(.c-note .c-label) {
		color: var(--grey1);
	}

	/* 结论：上下划线夹住，居中；整章的落点 */
	article :global(.c-punch) {
		background: none;
		border: none;
		border-top: 1px solid var(--bg4);
		border-bottom: 1px solid var(--bg4);
		color: var(--green);
		text-align: center;
		padding: 0.8em 0.6em;
		margin: 1.4em 0;
	}

	article :global(.c-punch > p) {
		margin: 0;
	}

	/* 两栏对照：把「预期/实际」这类并排放，差别一看就出来 */
	article :global(.c-cols) {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.8em;
		margin: 1em 0;
	}

	article :global(.c-col) {
		background: var(--bg1);
		border: 1px solid var(--bg4);
		padding: 0.55em 0.75em;
		min-width: 0; /* 允许内容收缩，否则宽代码块会把网格撑破 */
	}

	article :global(.c-col > p:first-child) {
		margin-top: 0;
	}

	article :global(.c-col > p:last-child) {
		margin-bottom: 0;
	}

	/* 窄屏下两栏并排放不下，摊成一栏 */
	@media (max-width: 640px) {
		article :global(.c-cols) {
			grid-template-columns: 1fr;
		}

		article :global(.c-box) {
			padding: 0.5em 0.7em;
		}
	}

	/* 窄屏下两栏并排放不下，摊成一栏 */
	@media (max-width: 640px) {
		article :global(.cv-columns) {
			grid-template-columns: 1fr;
		}
	}
</style>
