<script lang="ts">
	import { onMount } from 'svelte';
	import { marked } from 'marked';
	import DocumentToolbar from './DocumentToolbar.svelte';
	import { readFontScale, resetFontScale, stepFontScale } from '$lib/preview-zoom';
	import {
		isPresenting,
		nearestSlideIndex,
		setPresenting,
		stepSlide
	} from '$lib/presentation';
	import { isTextEntryTarget } from '$lib/text-entry';
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

	/* ---- 演示模式：把讲义当幻灯片翻 ---- */

	/**
	 * 演示状态放在模块里（见 $lib/presentation），因为 +page.svelte 的全局键盘处理
	 * 也要知道现在是不是在演示 —— 否则翻页的 ↑/↓ 会同时把左边文件树的光标挪走。
	 */
	let presenting = $state(isPresenting());
	/** 当前第几张（0 起），-1 表示这篇没有幻灯片。 */
	let slideIndex = $state(-1);
	/** 这篇有几张。 */
	let slideCount = $state(0);

	let slideLabel = $derived(slideIndex >= 0 ? `${slideIndex + 1} / ${slideCount}` : '');

	/** 每张幻灯片相对滚动容器的顶部偏移量。进演示时量一次，窗口尺寸变了再量。 */
	let slideOffsets: number[] = [];

	function measureSlides() {
		if (!pane) {
			slideOffsets = [];
			slideCount = 0;
			slideIndex = -1;
			return;
		}

		const slides = Array.from(pane.querySelectorAll<HTMLElement>('.c-slide'));
		slideCount = slides.length;

		if (slides.length === 0) {
			slideOffsets = [];
			slideIndex = -1;
			return;
		}

		const base = pane.getBoundingClientRect().top;
		slideOffsets = slides.map((slide) => slide.getBoundingClientRect().top - base + pane!.scrollTop);
		slideIndex = nearestSlideIndex(slideOffsets, pane.scrollTop);
	}

	function goToSlide(index: number) {
		if (!pane || index < 0 || index >= slideOffsets.length) return;
		pane.scrollTo({ top: slideOffsets[index], behavior: 'smooth' });
	}

	function stepPresentation(step: number) {
		goToSlide(stepSlide(slideIndex, step, slideCount));
	}

	function togglePresenting() {
		setPresenting(!presenting);
		presenting = isPresenting();
	}

	/**
	 * 进演示时量一次偏移量。退出时把滚动位置留在原处 —— 读者从哪张退出来的，
	 * 阅读模式就停在哪一段，不把人弹回开头。
	 */
	$effect(() => {
		if (!pane) return;
		if (!presenting) return;

		// 等一帧：切换瞬间 article 的样式还在改，量出来的偏移量是旧的
		const raf = requestAnimationFrame(() => measureSlides());
		return () => cancelAnimationFrame(raf);
	});

	/** 滚动时更新「现在第几张」。用 rAF 合流，避免每次 scroll 事件都做一次 DOM 测量。 */
	$effect(() => {
		if (!pane || !presenting) return;

		let queued = false;
		const onScroll = () => {
			if (queued) return;
			queued = true;
			requestAnimationFrame(() => {
				queued = false;
				if (pane) slideIndex = nearestSlideIndex(slideOffsets, pane.scrollTop);
			});
		};

		pane.addEventListener('scroll', onScroll, { passive: true });
		return () => pane?.removeEventListener('scroll', onScroll);
	});

	/** 窗口尺寸变了，偏移量全部失效 —— 重量一次，否则翻页会跳错地方。 */
	$effect(() => {
		if (!presenting) return;

		const onResize = () => measureSlides();
		window.addEventListener('resize', onResize);
		return () => window.removeEventListener('resize', onResize);
	});

	/**
	 * 演示时的键盘导航。挂在 window 上而不是容器上：演示时用户不会先去点一下文档，
	 * 焦点很可能还在左边的树上。
	 */
	$effect(() => {
		if (!presenting) return;

		const onKeydown = (event: KeyboardEvent) => {
			if (isTextEntryTarget(event.target)) return;

			switch (event.key) {
				case 'ArrowRight':
				case 'ArrowDown':
				case 'PageDown':
				case ' ':
					event.preventDefault();
					stepPresentation(1);
					break;
				case 'ArrowLeft':
				case 'ArrowUp':
				case 'PageUp':
					event.preventDefault();
					stepPresentation(-1);
					break;
				case 'Home':
					event.preventDefault();
					goToSlide(0);
					break;
				case 'End':
					event.preventDefault();
					goToSlide(slideCount - 1);
					break;
				case 'Escape':
					event.preventDefault();
					togglePresenting();
					break;
			}
		};

		window.addEventListener('keydown', onKeydown);
		return () => window.removeEventListener('keydown', onKeydown);
	});
</script>

{#if error}
	<div class="failure">
		<p>{kind} 渲染失败</p>
		<pre>{error.join('\n')}</pre>
	</div>
{:else}
	<DocumentToolbar
		bind:query
		{matchLabel}
		onFind={find}
		onZoom={zoom}
		{presenting}
		{slideLabel}
		onTogglePresent={togglePresenting}
	/>

	<div class="document-scroll" class:presenting bind:this={pane}>
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
		font-family: var(--font-chalk);
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
		font-family: var(--font-chalk);
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

	/* ---- 演示模式：一屏一张 ---- */

	/*
	 * 用 scroll-snap 做「翻页」。为什么不用真 PDF：typst 的 HTML 导出没有「页」这个概念
	 * （`#set page` 和 `#pagebreak()` 都是摆放原语，会被丢弃并报 warning），
	 * 而换 PDF 要付出按语义元素配色的能力。详见 $lib/presentation 顶部的取舍说明。
	 *
	 * 高度链：.document-scroll 是 flex:1 的滚动容器（高度确定）→ article 撑满它
	 * → 每张 c-slide 撑满 article。于是每张恰好一屏，不需要 vh 或容器查询单位。
	 */
	.document-scroll.presenting {
		scroll-snap-type: y mandatory;
	}

	.document-scroll.presenting article {
		height: 100%;
	}

	.document-scroll.presenting article :global(.c-slide) {
		height: 100%;
		box-sizing: border-box;
		scroll-snap-align: start;
		/* always：一次按键只翻一张，不因为滚动惯性连翻两三张 */
		scroll-snap-stop: always;
		display: flex;
		flex-direction: column;
		/* safe：内容比一屏高时不要把它顶部裁掉 */
		justify-content: safe center;
		padding: 3em 2.5em;
	}

	/*
	 * 演示时正文要大一点。演示是「一屋子人看一块屏」，阅读是「一个人凑近看」，
	 * 这两个场景该有不同的默认字号 —— 用户仍然可以用工具栏的 ± 覆盖。
	 */
	.document-scroll.presenting article :global(.c-slide > p),
	.document-scroll.presenting article :global(.c-slide li) {
		line-height: 1.75;
	}

	/* 演示时每张幻灯片之间画一条分隔，滚动过程中能看出边界在哪 */
	.document-scroll.presenting article :global(.c-slide + .c-slide) {
		border-top: 1px dashed var(--bg4);
	}

	/*
	 * 打印 / 另存为 PDF。浏览器打印是唯一「从 HTML 拿到真分页」的途径 ——
	 * 它走的是另一套排版引擎（paged media），不经过 typst 的 HTML 导出，
	 * 所以这里的 `break-before` 是真管用的。
	 *
	 * 粉笔滤镜打印出来是糊的，底色也费墨，一并去掉。
	 */
	@media print {
		article {
			filter: none;
		}

		article :global(.c-slide) {
			break-before: page;
			break-inside: avoid;
		}

		article :global(.c-slide:first-of-type) {
			break-before: auto;
		}

		/* 深色底打印会变成一片黑，翻成白底黑字 */
		article :global(.c-box),
		article :global(.c-col),
		article :global(pre) {
			background: none;
			border-color: #999;
		}
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
