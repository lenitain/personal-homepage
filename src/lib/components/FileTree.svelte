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
	let rowElements = $state<(HTMLElement | undefined)[]>([]);

	$effect(() => {
		const index = rows.findIndex((row) => row.entry.path === cursorPath);
		if (index === -1) return;
		rowElements[index]?.scrollIntoView({ block: 'nearest' });
	});

	/** 每一层缩进多少像素。层级只靠这个偏移表达 —— 不画缩进参考线。 */
	const INDENT_STEP = 20;
	/** 第一层的左内边距。 */
	const INDENT_BASE = 6;

	/** 一个树行的左内边距：深度越深缩进越多。 */
	function indentation(depth: number): string {
		return `padding-left: ${INDENT_BASE + depth * INDENT_STEP}px`;
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
			style={indentation(row.depth)}
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
	}

	.row {
		display: flex;
		align-items: center;
		width: 100%;
		padding-right: 6px;
		border: none;
		background-color: transparent;
		color: var(--fg);
		font: inherit;
		font-size: 0.95em;
		line-height: 1.45;
		text-align: left;
		white-space: nowrap;
		cursor: default;
	}

	.row.cursor {
		background-color: var(--bg3);
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
