<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { slide } from 'svelte/transition';
	import { SvelteSet } from 'svelte/reactivity';
	import ChalkFilter from '$lib/components/ChalkFilter.svelte';
	import FileTree from '$lib/components/FileTree.svelte';
	import ContentPane from '$lib/components/ContentPane.svelte';
	import Status from '$lib/components/Status.svelte';
	import { findFileTreeEntry, flattenFileTree } from '$lib/file-tree';
	import { PAGE_STEP, arrowLeft, arrowRight, stepCursorPath, typeAheadPath } from '$lib/tree-nav';
	import { isPresenting } from '$lib/presentation';
	import { isTextEntryTarget } from '$lib/text-entry';
	import {
		browseStateOf,
		browseStateToSearch,
		parseBrowseState,
		resolveBrowseState,
		shouldCreateHistoryEntry
	} from '$lib/browse-state';
	import type { ArrowLeftIntent, ArrowRightIntent } from '$lib/tree-nav';
	import type { HistoryWrite } from '$lib/browse-state';
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

	/**
	 * 展开了哪些目录。首屏这份来自地址栏（`data.initialExpanded`）—— 刷新前开着的文件夹，
	 * 刷新后还是开着的。空集合 = 全部折叠。
	 *
	 * `untrack` 是给编译器看的：这里**故意**只取一次初始值，之后这份集合由点击和
	 * 后退/前进改，不该再跟着 props 变。
	 */
	const expandedPaths = new SvelteSet<string>(untrack(() => data.initialExpanded));

	/** 拍平后的可见行 —— 渲染与键盘导航共用同一份顺序；声明在光标之前，初始化时要用。 */
	let rows = $derived(flattenFileTree(tree, expandedPaths));

	/** 光标只允许停在看得见的行上：路径不在可见行里（树空、文档藏在折叠目录里）就是 null。 */
	function visibleCursorPath(path: string | null): string | null {
		return path && rows.some((row) => row.entry.path === path) ? path : null;
	}

	/**
	 * 光标：键盘停在哪一行，也是「选中即所见」里的那个「选中」——
	 * 停在文件行上时右栏显示的就是它（编辑器式的「光标 ≠ 打开」两态在这里合一，
	 * 于是 readme 不再需要教人「按 Enter 才真的打开」）；停在目录行上时右栏保持
	 * 上一篇不动 —— 目录没有内容可预览。首屏指向正在读的那篇，一进站高亮就在它身上。
	 */
	let cursorPath = $state<string | null>(
		untrack(() => visibleCursorPath(data.restoredFile ?? data.defaultPath))
	);
	/**
	 * 地址栏指名的那一篇。真相来源是 URL，不是组件内存 —— 点击只是改 URL，右栏跟着走。
	 * 这一份是服务端按树校验过的；URL 什么都没说时是 null。同上的「只取一次」。
	 */
	let urlFile = $state<string | null>(untrack(() => data.restoredFile));
	let openPath = $derived(urlFile ?? data.defaultPath);
	/** 左侧整栏是否展开。 */
	let sidebarOpen = $state(true);
	/**
	 * 视口是否窄到放不下并排两栏。窄的时候左栏变成盖在正文上的浮层，并且默认收起 ——
	 * 否则 280px 的树会把正文挤成一条几十像素的缝，整页没法读。
	 */
	let narrowViewport = $state(false);

	/** 窄边条的提示文字，跟着开合状态走。 */
	let sidebarToggleLabel = $derived(sidebarOpen ? '收起文件树' : '展开文件树');

	let openEntry = $derived(openPath ? findFileTreeEntry(tree, openPath) : null);

	// Randomize seeds once per page load (refresh = new board)
	let wobbleSeed = $state(Math.floor(Math.random() * 10000));
	let chalkSeed = $state(Math.floor(Math.random() * 10000));
	let boardSeed = $state(Math.floor(Math.random() * 10000));

	function toggleSidebar() {
		sidebarOpen = !sidebarOpen;
	}

	/** 上一次往历史里新开一条的时刻（`Date.now()`）；0 = 还没开过。见 shouldCreateHistoryEntry。 */
	let lastPushAt = 0;

	/**
	 * 把当前浏览位置写回地址栏。`write` 决定历史记录的粒度
	 * （依据见 `shouldCreateHistoryEntry` 的文档）：
	 *
	 * - `'push'` …… 点击 / Enter 确认打开：无条件新开一条，后退键回到上一篇；
	 * - `'replace'` …… 开合目录：视图偏好，绝不往历史里塞记录 —— 否则点开五个
	 *   文件夹、再想后退回上一篇文章，得按七次；
	 * - `'move'` …… ↑/↓ 选中即打开的连续浏览：停留不足一秒就并进上一条，
	 *   按住方向键翻十几篇文章不会把历史撑爆。
	 *
	 * 用原生 History API，而不是 `$app/navigation` 的同名函数：SvelteKit 的 `pushState`
	 * 只写 `history.state`，不更新 `page.url`，而且那份 state 刷新后不会被应用（官方文档
	 * Shallow routing → Caveats 明说）。这里要的恰恰是地址栏本身 —— 直接改地址栏，它就
	 * 是那份持久化存储。我们插进去的记录不带 SvelteKit 的记账，它的路由器会走 popstate
	 * 的兜底分支，不会为此重跑 `load`（正文是整体内联的，重跑一次就是重传整站内容）。
	 */
	function syncUrl(write: HistoryWrite) {
		const url = `${location.pathname}${browseStateToSearch(browseStateOf(urlFile, expandedPaths))}`;
		if (url === `${location.pathname}${location.search}`) return;

		if (shouldCreateHistoryEntry(write, Date.now(), lastPushAt)) {
			history.pushState(null, '', url);
			lastPushAt = Date.now();
		} else {
			history.replaceState(null, '', url);
		}
	}

	/** 整份换掉展开集合 —— 后退/前进要复原的是「那时开着哪些文件夹」，不是增量。 */
	function replaceExpanded(paths: string[]) {
		expandedPaths.clear();
		for (const path of paths) expandedPaths.add(path);

		// 光标不能悬在一个刚被收起来、已经看不见的节点上（同 toggleDirectory）
		if (cursorPath && !rows.some((row) => row.entry.path === cursorPath)) {
			cursorPath = null;
		}
	}

	/** 后退 / 前进。读 `location.search` 而不是 `page.url`：我们自己插的历史记录不带框架的记账。 */
	function handlePopstate() {
		const restored = resolveBrowseState(tree, parseBrowseState(location.search));
		urlFile = restored.file;
		replaceExpanded(restored.expanded);
		// 后退 / 前进要连光标一起复原：回到哪篇，高亮就落回哪篇
		cursorPath = visibleCursorPath(restored.file ?? data.defaultPath);
	}

	/**
	 * 开合一个目录。方向由 `expandedPaths` 里「现在有没有它」决定，所以
	 * ←/→ 算出来的「展开 / 收起」意图和单击一行走的是同一条路。
	 * 开合是视图偏好，写地址栏走 `replace`，不进历史。
	 */
	function toggleDirectory(path: string) {
		if (!expandedPaths.has(path)) {
			expandedPaths.add(path);
		} else {
			expandedPaths.delete(path);
			// 光标不能悬在一个刚被收起、已经看不见的节点上
			if (cursorPath?.startsWith(`${path}/`)) {
				cursorPath = path;
			}
		}

		syncUrl('replace');
	}

	/**
	 * 确认打开一行（点击 / Enter）：目录就展开/收起，文件就打开，两种情况都把光标带过去。
	 * 与 ↑/↓ 的「选中即预览」（setCursor）相比，这是明确的意图：新开一条历史记录，
	 * 窄屏下打开文件还顺手收起盖在正文上的浮层树。
	 */
	function activateEntry(entry: FsEntry) {
		cursorPath = entry.path;
		if (entry.type === 'dir') {
			toggleDirectory(entry.path);
			return;
		}

		urlFile = entry.path;
		// 窄屏下树是浮层：确认打开文章就收起来，不然文章还被盖着
		if (narrowViewport) sidebarOpen = false;
		syncUrl('push');
	}

	/**
	 * 把光标落到某一行 —— 键盘导航的唯一出口，「选中即所见」在这里实现：
	 * 落在文件行上就顺手打开它，并按 `write` 的等级写地址栏；落在目录行上只移动
	 * 高亮，右栏保持上一篇（目录没有内容可看），URL 不动。
	 */
	function setCursor(path: string, write: HistoryWrite) {
		// 落点就是现在这行（比如在最后一行还按 ↓、首字母只有自己匹配）：什么都没发生，
		// 不写 URL、不动历史 —— 否则一次原地不动会凭空 push 出一条 ?file= 记录
		if (path === cursorPath) return;

		cursorPath = path;
		const row = rows.find((candidate) => candidate.entry.path === path);
		if (row?.entry.type !== 'file') return;

		urlFile = path;
		// 窄屏下不收起树：连续 ↑/↓ 浏览时浮层反复出没，比盖住正文更烦人。
		// 收起只发生在「确认打开」（点击 / Enter）的 activateEntry 里。
		syncUrl(write);
	}

	/** ↑/↓、PageUp/PageDown 的一步。落点计算在 tree-nav 里（纯函数、有单测）。 */
	function moveCursor(step: number) {
		const next = stepCursorPath(rows, cursorPath, openPath, step);
		if (next !== null) setCursor(next, 'move');
	}

	/** Home / End：落到可见行的头 / 尾。 */
	function focusRowEdge(toEnd: boolean) {
		const row = toEnd ? rows[rows.length - 1] : rows[0];
		if (row) setCursor(row.entry.path, 'move');
	}

	/** 把 ←/→ 算出的意图落到状态上：展开/收起是视图偏好，focus 是浏览移动。 */
	function applyArrowIntent(intent: ArrowRightIntent | ArrowLeftIntent | null) {
		if (!intent) return;
		if (intent.kind === 'expand' || intent.kind === 'collapse') {
			toggleDirectory(intent.path);
		} else {
			setCursor(intent.path, 'move');
		}
	}

	function activateCursor() {
		const row = rows.find((candidate) => candidate.entry.path === cursorPath);
		if (row) activateEntry(row.entry);
	}

	function handleKeydown(event: KeyboardEvent) {
		// 演示模式接管方向键和空格（翻页）。这里必须让路，否则翻一张幻灯片
		// 会把左边文件树的光标也顺带挪一格，而用户完全看不见这件事。
		if (isPresenting()) return;

		// 树收起来的时候不给键盘操作，免得看不见的光标在动
		if (!sidebarOpen) return;

		// 焦点在输入控件里时一律让路：否则在文档搜索框里打字会把文件树的光标挪走、
		// Enter 还会顺手打开一篇文件
		if (isTextEntryTarget(event.target)) return;

		// 带修饰键的组合让给浏览器和各处自己的快捷键（Ctrl+F 搜索、Alt+← 后退……）
		if (event.ctrlKey || event.metaKey || event.altKey) return;

		switch (event.key) {
			case 'ArrowDown':
				event.preventDefault();
				moveCursor(1);
				break;
			case 'ArrowUp':
				event.preventDefault();
				moveCursor(-1);
				break;
			case 'ArrowRight':
				// 资源管理器约定：→ 展开折叠的目录 / 走进已展开目录的子项。
				// 无论算不算得出意图都要 preventDefault：部分浏览器的「前进」也用 →，
				// 树活着的时候不能被它偷走历史导航。
				event.preventDefault();
				applyArrowIntent(arrowRight(rows, cursorPath));
				break;
			case 'ArrowLeft':
				// 同上：← 是收起 / 回父级，不是浏览器后退
				event.preventDefault();
				applyArrowIntent(arrowLeft(rows, cursorPath));
				break;
			case 'Home':
				event.preventDefault();
				focusRowEdge(false);
				break;
			case 'End':
				event.preventDefault();
				focusRowEdge(true);
				break;
			case 'PageUp':
				event.preventDefault();
				moveCursor(-PAGE_STEP);
				break;
			case 'PageDown':
				event.preventDefault();
				moveCursor(PAGE_STEP);
				break;
			case 'Enter':
				event.preventDefault();
				activateCursor();
				break;
			default: {
				// 首字母跳转（文件管理器标配）。空格留给正文自己滚动；IME 合成中的
				// 中间键不掺和；没匹配上就不 preventDefault，把按键还给浏览器。
				if (event.isComposing || event.key === 'Process') break;
				if (event.key.length !== 1 || event.key === ' ') break;

				const target = typeAheadPath(rows, cursorPath, event.key);
				if (target) {
					event.preventDefault();
					setCursor(target, 'move');
				}
			}
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
		window.addEventListener('popstate', handlePopstate);

		/*
		 * 地址栏规范化：把失效的 file=、树里没有的 dirs=、重复项、参数顺序一次性理顺，
		 * 于是访客不会停在 `/?file=已删除.md&dirs=不存在` 这种地址上。走 replaceState，
		 * 不留一条脏历史记录。
		 */
		syncUrl('replace');

		return () => {
			narrow.removeEventListener('change', handleViewportChange);
			document.removeEventListener('keydown', handleKeydown);
			window.removeEventListener('popstate', handlePopstate);
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

	<Status entry={openEntry} />
</div>

<style>
	.chalk-app {
		display: flex;
		flex-direction: column;
		height: 100vh;
		width: 100vw;
		background: var(--bg0);
		color: var(--fg);
		font-family: var(--font-chalk);
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

	/* Chalk writing: character wobble + grain breakup.
	   只套在真正是「文字」的渲染区上：树、状态栏，以及自己套滤镜的正文
	   （正文的 article 在 DocumentView 里）。整栏套滤镜会让大滚动区每帧重栅格化。 */
	.chalk-app :global(.file-tree),
	.chalk-app :global(footer) {
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
