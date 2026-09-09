<script lang="ts">
	import { onMount } from 'svelte';
	import ChalkFilter from '$lib/components/ChalkFilter.svelte';
	import Header from '$lib/components/Header.svelte';
	import FileList from '$lib/components/FileList.svelte';
	import ContentPane from '$lib/components/ContentPane.svelte';
	import Status from '$lib/components/Status.svelte';
	import type { FsEntry } from '$lib/types';

	let { data } = $props();

	let tree = $derived(data.tree as FsEntry);
	let pathParts = $state<string[]>(['~']);
	let selectedIndex = $state(data.initialIndex);
	let indexStack: number[] = $state([]);

	function resolve(root: FsEntry, path: string[]): FsEntry {
		let current = root;
		for (const segment of path) {
			if (segment === '~') continue;
			if (!current.children) return current;
			const child = current.children.find((c) => c.name === segment);
			if (!child) return current;
			current = child;
		}
		return current;
	}

	let currentDir = $derived(resolve(tree, pathParts));
	let entries = $derived(currentDir.children ?? []);
	let selectedEntry = $derived(entries[selectedIndex] ?? null);
	let cwd = $derived(pathParts.join('/'));

	// Randomize seeds once per page load (refresh = new board)
	let wobbleSeed = $state(Math.floor(Math.random() * 10000));
	let chalkSeed = $state(Math.floor(Math.random() * 10000));
	let boardSeed = $state(Math.floor(Math.random() * 10000));

	function select(index: number) {
		selectedIndex = Math.max(0, Math.min(index, entries.length - 1));
	}

	function open(entry: FsEntry) {
		if (entry.type === 'dir') {
			indexStack = [...indexStack, selectedIndex];
			pathParts = [...pathParts, entry.name];
			selectedIndex = 0;
		}
	}

	function goUp() {
		if (pathParts.length > 1) {
			pathParts = pathParts.slice(0, -1);
			selectedIndex = indexStack[indexStack.length - 1] ?? 0;
			indexStack = indexStack.slice(0, -1);
		}
	}

	function handleKeydown(e: KeyboardEvent) {
		switch (e.key) {
			case 'ArrowDown':
				e.preventDefault();
				select(selectedIndex + 1);
				break;
			case 'ArrowUp':
				e.preventDefault();
				select(selectedIndex - 1);
				break;
			case 'Enter':
			case 'ArrowRight':
				e.preventDefault();
				if (selectedEntry) open(selectedEntry);
				break;
			case 'Escape':
			case 'Backspace':
			case 'ArrowLeft':
				e.preventDefault();
				goUp();
				break;
		}
	}

	onMount(() => {
		document.addEventListener('keydown', handleKeydown);
		return () => document.removeEventListener('keydown', handleKeydown);
	});
</script>

<ChalkFilter {wobbleSeed} {chalkSeed} {boardSeed} />

<div class="yazi-app">
	<Header {cwd} />

	<main>
		<div class="panel left">
			<FileList
				{entries}
				{selectedIndex}
				onSelect={select}
				onOpen={open}
			/>
		</div>

		<div class="divider"></div>

		<div class="panel right">
			<ContentPane entry={selectedEntry} />
		</div>
	</main>

	<Status entry={selectedEntry} parentCount={entries.length} />
</div>

<style>
	.yazi-app {
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
	.yazi-app::after {
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
	.yazi-app :global(header),
	.yazi-app :global(footer),
	.yazi-app :global(.file-list),
	.yazi-app :global(.content-pane) {
		filter: url(#chalk-writing);
	}


	main {
		display: flex;
		flex: 1;
		overflow: hidden;
	}

	.panel {
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	.left {
		flex: 0.29;
	}

	.right {
		flex: 0.71;
	}

	.divider {
		width: 1px;
		background: var(--bg4);
		flex-shrink: 0;
	}
</style>
