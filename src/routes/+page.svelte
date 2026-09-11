<script lang="ts">
	import { onMount } from 'svelte';
	import { slide } from 'svelte/transition';
	import { SvelteSet } from 'svelte/reactivity';
	import ChalkFilter from '$lib/components/ChalkFilter.svelte';
	import FileTree from '$lib/components/FileTree.svelte';
	import ContentPane from '$lib/components/ContentPane.svelte';
	import Status from '$lib/components/Status.svelte';
	import { countFileTreeFiles, findFileTreeEntry, flattenFileTree } from '$lib/file-tree';
	import type { FsEntry } from '$lib/types';

	let { data } = $props();

	/** 必须和样式表里那条 @media 断点保持一致。 */
	const NARROW_VIEWPORT_QUERY = '(max-width: 640px)';

	/** 左栏开合动画时长。短一点：这是个导航动作，不该让人等它演完。 */
	const SIDEBAR_SLIDE_MS = 160;

	/** 系统开了「减少动态效果」就把时长归零。SSR 阶段没有 window，先按正常时长走。 */
	function sidebarSlideDuration(): number {
		if (typeof window === 'undefined') return SIDEBAR_SLIDE_MS;
		return window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : SIDEBAR_SLIDE_MS;
	}

	const tree = $derived(data.tree);

	/** 展开了哪些目录。空集合 = 全部折叠，这就是首屏的样子。 */
	const expandedPaths = new SvelteSet<string>();
	/** 光标：键盘现在停在哪一行。跟右栏显示哪一篇是两件事。 */
	let cursorPath = $state<string | null>(null);
	/** 访客自己点开的那一篇；还没点过就跟着页面数据给的默认文档走。 */
	let chosenPath = $state<string | null>(null);
	let openPath = $derived(chosenPath ?? data.initialPath);
	/** 左侧整栏是否展开。 */
	let sidebarOpen = $state(true);
	/**
	 * 视口是否窄到放不下并排两栏。窄的时候左栏变成盖在正文上的浮层，并且默认收起 ——
	 * 否则 280px 的树会把正文挤成一条几十像素的缝，整页没法读。
	 */
	let narrowViewport = $state(false);

	/** 窄边条的提示文字，跟着开合状态走。 */
	let sidebarToggleLabel = $derived(sidebarOpen ? '收起文件树' : '展开文件树');

	let rows = $derived(flattenFileTree(tree, expandedPaths));
	let openEntry = $derived(openPath ? findFileTreeEntry(tree, openPath) : null);
	let fileCount = $derived(countFileTreeFiles(tree));

	// Randomize seeds once per page load (refresh = new board)
	let wobbleSeed = $state(Math.floor(Math.random() * 10000));
	let chalkSeed = $state(Math.floor(Math.random() * 10000));
	let boardSeed = $state(Math.floor(Math.random() * 10000));

	function toggleSidebar() {
		sidebarOpen = !sidebarOpen;
	}

	function toggleDirectory(entry: FsEntry) {
		if (!expandedPaths.has(entry.path)) {
			expandedPaths.add(entry.path);
			return;
		}

		expandedPaths.delete(entry.path);
		// 光标不能悬在一个刚被收起、已经看不见的节点上
		if (cursorPath?.startsWith(`${entry.path}/`)) {
			cursorPath = entry.path;
		}
	}

	/** 单击一行：目录就展开/收起，文件就打开。两种情况都把光标带过去。 */
	function activateEntry(entry: FsEntry) {
		cursorPath = entry.path;
		if (entry.type === 'dir') {
			toggleDirectory(entry);
		} else {
			chosenPath = entry.path;
			// 窄屏下树是浮层：选完文章就收起来，不然文章还被盖着
			if (narrowViewport) sidebarOpen = false;
		}
	}

	function moveCursor(step: number) {
		if (rows.length === 0) return;

		const current = rows.findIndex((row) => row.entry.path === cursorPath);
		if (current === -1) {
			// 还没有光标：第一次移动时落到正在看的那篇；没打开任何文章就落到可见行的头/尾
			const opened = rows.findIndex((row) => row.entry.path === openPath);
			const target = opened !== -1 ? opened : step > 0 ? 0 : rows.length - 1;
			cursorPath = rows[target].entry.path;
			return;
		}

		const next = Math.min(Math.max(current + step, 0), rows.length - 1);
		cursorPath = rows[next].entry.path;
	}

	function activateCursor() {
		const row = rows.find((candidate) => candidate.entry.path === cursorPath);
		if (row) activateEntry(row.entry);
	}

	function handleKeydown(event: KeyboardEvent) {
		// 树收起来的时候不给键盘操作，免得看不见的光标在动
		if (!sidebarOpen) return;

		switch (event.key) {
			case 'ArrowDown':
				event.preventDefault();
				moveCursor(1);
				break;
			case 'ArrowUp':
				event.preventDefault();
				moveCursor(-1);
				break;
			case 'Enter':
				event.preventDefault();
				activateCursor();
				break;
		}
	}

	onMount(() => {
		const narrow = window.matchMedia(NARROW_VIEWPORT_QUERY);
		narrowViewport = narrow.matches;
		if (narrowViewport) sidebarOpen = false;

		const handleViewportChange = (event: MediaQueryListEvent) => {
			narrowViewport = event.matches;
		};

		narrow.addEventListener('change', handleViewportChange);
		document.addEventListener('keydown', handleKeydown);

		return () => {
			narrow.removeEventListener('change', handleViewportChange);
			document.removeEventListener('keydown', handleKeydown);
		};
	});
</script>

<ChalkFilter {wobbleSeed} {chalkSeed} {boardSeed} />

<div class="chalk-app">
	<main>
		<!--
			最左侧这条常驻的窄边条本身就是文件树的开关：展开时它显示 « 点了收起，
			收起时显示 » 点了展开。位置永远不动，不收起来、也不换成别的按钮。
		-->
		<button
			type="button"
			class="rail"
			title={sidebarToggleLabel}
			aria-label={sidebarToggleLabel}
			aria-expanded={sidebarOpen}
			onclick={toggleSidebar}>{sidebarOpen ? '«' : '»'}</button
		>

		{#if sidebarOpen}
			<aside
				class="sidebar"
				transition:slide={{ axis: 'x', duration: sidebarSlideDuration() }}
			>
				<div class="sidebar-inner">
					<FileTree {rows} {cursorPath} {openPath} onActivate={activateEntry} />
				</div>
			</aside>
		{/if}

		<div class="pane">
			{#key openPath}
				<ContentPane entry={openEntry} />
			{/key}
		</div>
	</main>

	<Status entry={openEntry} {fileCount} />
</div>

<style>
	.chalk-app {
		display: flex;
		flex-direction: column;
		height: 100vh;
		width: 100vw;
		background: var(--bg0);
		color: var(--fg);
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
		position: relative;
	}

	/* Board texture: coarse slate surface, separate layer.
	   multiply (not overlay): the grain only darkens the board
	   like real slate pitting, instead of laying a milky film
	   over the whole viewport. */
	.chalk-app::after {
		content: '';
		position: fixed;
		inset: 0;
		filter: url(#board-texture);
		mix-blend-mode: multiply;
		opacity: 0.05;
		pointer-events: none;
		z-index: 9999;
	}

	/* Chalk writing: character wobble + grain breakup */
	.chalk-app :global(.file-tree),
	.chalk-app :global(footer),
	.chalk-app :global(.content-pane) {
		filter: url(#chalk-writing);
	}

	main {
		display: flex;
		flex: 1;
		overflow: hidden;
		position: relative;
		/* 窄边条的宽度。窄视口下浮层要靠它避让，所以两处共用同一个值。 */
		--rail-width: 22px;
	}

	.sidebar {
		display: flex;
		flex-direction: column;
		width: 280px;
		flex-shrink: 0;
		overflow: hidden;
	}

	/*
	 * 定宽内层。开合动画改的是外层的宽度，内层不动 —— 于是动画看起来是
	 * 「从窄边条那里展开 / 卷回去」，而不是把树里的文件名一路挤扁。
	 */
	.sidebar-inner {
		display: flex;
		flex-direction: column;
		flex: 1;
		width: 280px;
		min-height: 0;
	}

	/* 常驻最左侧的开合开关。位置永远不动，只有字形跟着开合状态变。
	   它不画右边框：分割线统一交给 .pane 的 border-left，这样任何状态下
	   都只有一条线，而且永远贴在正文左边缘、跟着开合动画一起走。 */
	.rail {
		display: flex;
		justify-content: center;
		align-items: flex-start;
		width: var(--rail-width);
		flex-shrink: 0;
		padding-top: 3px;
		border: none;
		background: var(--bg1);
		color: var(--grey1);
		font: inherit;
		font-size: 0.85em;
		line-height: 1;
		cursor: pointer;
	}

	.rail:hover {
		background: var(--bg2);
		color: var(--fg);
	}

	.pane {
		display: flex;
		flex-direction: column;
		flex: 1;
		/* 不加这条，长代码块会把右栏撑破 */
		min-width: 0;
		overflow: hidden;
		/* 唯一的竖分割线：贴着正文左边缘，开合动画期间跟着一起移动 */
		border-left: 1px solid var(--bg4);
	}

	/*
	 * 窄视口（断点必须和脚本里的 NARROW_VIEWPORT_QUERY 一致）：
	 * 并排放不下两栏，于是树改成盖在正文上的浮层，宽度也跟着视口收缩。
	 * 左边缘要让开窄边条 —— 不然浮层会盖住开关，收不起来。
	 * 默认收起的状态由脚本设置。
	 */
	@media (max-width: 640px) {
		.sidebar {
			position: absolute;
			top: 0;
			bottom: 0;
			left: var(--rail-width);
			z-index: 10;
			width: min(280px, calc(100vw - var(--rail-width) - 24px));
			background: var(--bg0);
			box-shadow: 2px 0 14px rgb(0 0 0 / 0.45);
		}
	}
</style>
