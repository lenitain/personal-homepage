<script lang="ts">
	import { onMount } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import ChalkFilter from '$lib/components/ChalkFilter.svelte';
	import FileTree from '$lib/components/FileTree.svelte';
	import ContentPane from '$lib/components/ContentPane.svelte';
	import Status from '$lib/components/Status.svelte';
	import { countFileTreeFiles, findFileTreeEntry, flattenFileTree } from '$lib/file-tree';
	import type { FsEntry } from '$lib/types';

	let { data } = $props();

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

	let rows = $derived(flattenFileTree(tree, expandedPaths));
	let openEntry = $derived(openPath ? findFileTreeEntry(tree, openPath) : null);
	let fileCount = $derived(countFileTreeFiles(tree));

	// Randomize seeds once per page load (refresh = new board)
	let wobbleSeed = $state(Math.floor(Math.random() * 10000));
	let chalkSeed = $state(Math.floor(Math.random() * 10000));
	let boardSeed = $state(Math.floor(Math.random() * 10000));

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
		document.addEventListener('keydown', handleKeydown);
		return () => document.removeEventListener('keydown', handleKeydown);
	});
</script>

<ChalkFilter {wobbleSeed} {chalkSeed} {boardSeed} />

<div class="chalk-app">
	<main>
		{#if sidebarOpen}
			<aside class="sidebar">
				<div class="sidebar-tools">
					<button
						type="button"
						class="collapse"
						title="收起文件树"
						aria-label="收起文件树"
						onclick={() => (sidebarOpen = false)}>«</button
					>
				</div>
				<FileTree {rows} {cursorPath} {openPath} onActivate={activateEntry} />
			</aside>
		{:else}
			<button
				type="button"
				class="rail"
				title="展开文件树"
				aria-label="展开文件树"
				onclick={() => (sidebarOpen = true)}>»</button
			>
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
	}

	.sidebar {
		display: flex;
		flex-direction: column;
		width: 280px;
		flex-shrink: 0;
		border-right: 1px solid var(--bg4);
		overflow: hidden;
	}

	.sidebar-tools {
		display: flex;
		justify-content: flex-end;
		align-items: center;
		height: 18px;
		padding-right: 4px;
		flex-shrink: 0;
	}

	.collapse {
		border: none;
		background: none;
		color: var(--grey1);
		font: inherit;
		font-size: 0.85em;
		line-height: 1;
		padding: 1px 5px;
		border-radius: 3px;
		cursor: pointer;
	}

	.collapse:hover {
		color: var(--fg);
		background: var(--bg2);
	}

	.rail {
		display: flex;
		justify-content: center;
		align-items: flex-start;
		width: 22px;
		flex-shrink: 0;
		padding-top: 2px;
		border: none;
		border-right: 1px solid var(--bg4);
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
	}
</style>
