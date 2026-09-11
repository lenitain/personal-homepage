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

	/** 每一层缩进多少像素。 */
	const INDENT_STEP = 20;
	/** 第一层的左内边距。 */
	const INDENT_BASE = 6;
	/** 缩进参考线画在第一层子项的起始位置。 */
	const FIRST_GUIDE_X = INDENT_BASE + INDENT_STEP;

	/**
	 * 一个树行的行内样式：缩进，加上只覆盖这一行高度的缩进参考线。
	 *
	 * 参考线必须画在每一行上，不能画在 .file-tree 面板上 —— 面板是全高的，
	 * 画上去会从面板顶一直拉到面板底，在最后一行下面留一条几百像素的悬空竖线。
	 * 画在行上，连续几行自然拼成一条通到底的线，最后一行之后就干净地断掉。
	 */
	function rowStyle(depth: number): string {
		const paddingLeft = `${INDENT_BASE + depth * INDENT_STEP}px`;
		if (depth === 0) return `padding-left: ${paddingLeft}`;

		// 每一层祖先各一条 1px 竖线：用固定周期的重复渐变，再用 background-size
		// 把它裁到「depth 条线」的宽度，于是深层缩进也能自动对齐。
		return [
			`padding-left: ${paddingLeft}`,
			`background-image: repeating-linear-gradient(to right, var(--bg4) 0 1px, transparent 1px ${INDENT_STEP}px)`,
			`background-size: ${depth * INDENT_STEP}px 100%`,
			`background-position: ${FIRST_GUIDE_X}px 0`,
			'background-repeat: no-repeat'
		].join('; ');
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
			style={rowStyle(row.depth)}
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
		/* 只用 background-color：写成 background 简写会把行内样式里的
		   缩进参考线（background-image）一并清掉 */
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
