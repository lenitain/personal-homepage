<script lang="ts">
	import type { FsEntry, TreeRow } from '$lib/types';

	let {
		rows,
		cursorPath = null,
		openPath = null,
		onActivate
	}: {
		rows: TreeRow[];
		cursorPath?: string | null;
		openPath?: string | null;
		onActivate?: (entry: FsEntry) => void;
	} = $props();

	// 键盘移动光标时，把跑到可视区外面的那一行拉回来。
	let rowElements: (HTMLElement | undefined)[] = [];

	$effect(() => {
		const index = rows.findIndex((row) => row.entry.path === cursorPath);
		if (index === -1) return;
		rowElements[index]?.scrollIntoView({ block: 'nearest' });
	});

	function indent(depth: number): string {
		return `${6 + depth * 20}px`;
	}
</script>

<div class="file-tree" role="tree" aria-label="content">
	{#each rows as row, i (row.entry.path)}
		<button
			type="button"
			class="row"
			class:cursor={row.entry.path === cursorPath}
			class:opened={row.entry.path === openPath}
			role="treeitem"
			tabindex="-1"
			aria-level={row.depth + 1}
			aria-selected={row.entry.path === cursorPath}
			aria-expanded={row.entry.type === 'dir' ? row.expanded : undefined}
			style="padding-left: {indent(row.depth)}"
			bind:this={rowElements[i]}
			onclick={() => onActivate?.(row.entry)}
		>
			<span class="caret">{row.entry.type === 'dir' ? (row.expanded ? '▾' : '▸') : ''}</span>
			<span class="name" class:dir={row.entry.type === 'dir'}>{row.entry.name}</span>
		</button>
	{/each}
</div>

<style>
	.file-tree {
		flex: 1;
		overflow-y: auto;
		overflow-x: hidden;
		background: var(--bg0);
		/* 缩进参考线：和设计稿一致，画在第一层缩进的起点上 */
		background-image: linear-gradient(var(--bg4), var(--bg4));
		background-size: 1px 100%;
		background-repeat: no-repeat;
		background-position: 26px 0;
	}

	.row {
		display: flex;
		align-items: center;
		width: 100%;
		padding-right: 6px;
		border: none;
		background: none;
		color: var(--fg);
		font: inherit;
		font-size: 0.95em;
		line-height: 1.45;
		text-align: left;
		white-space: nowrap;
		cursor: default;
	}

	.row.cursor {
		background: var(--bg3);
	}

	.row.opened .name {
		color: var(--orange);
	}

	.caret {
		flex-shrink: 0;
		width: 1.1em;
		color: var(--grey1);
		font-size: 0.8em;
	}

	.name {
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.dir {
		color: var(--green);
		font-weight: bold;
	}
</style>
