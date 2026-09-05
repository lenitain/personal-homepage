<script lang="ts">
	import type { FsEntry } from '$lib/types';

	let {
		entries,
		selectedIndex = -1,
		onSelect,
		onOpen,
	}: {
		entries: FsEntry[];
		selectedIndex?: number;
		onSelect?: (index: number) => void;
		onOpen?: (entry: FsEntry) => void;
	} = $props();

	function icon(entry: FsEntry): string {
		return entry.type === 'dir' ? '📁' : '📄';
	}

	function colorClass(entry: FsEntry): string {
		if (entry.type === 'dir') return 'dir';
		if (entry.name.endsWith('.md')) return 'markdown';
		return 'file';
	}
</script>

<div class="file-list" role="listbox">
	{#each entries as entry, i}
		<div
			class="entry"
			class:selected={i === selectedIndex}
			role="option"
			tabindex="-1"
			aria-selected={i === selectedIndex}
			onclick={() => onSelect?.(i)}
			ondblclick={() => onOpen?.(entry)}
		>
			<span class="icon">{icon(entry)}</span>
			<span class="name {colorClass(entry)}">{entry.name}</span>
		</div>
	{/each}
</div>

<style>
	.file-list {
		flex: 1;
		overflow-y: auto;
		background: var(--bg0);
	}

	.entry {
		display: flex;
		align-items: center;
		padding: 0 0.6em;
		height: 1.4em;
		cursor: default;
		white-space: nowrap;
		overflow: hidden;
	}

	.entry.selected {
		background: var(--bg3);
	}

	.icon {
		flex-shrink: 0;
		width: 1.8em;
		font-size: 0.85em;
	}

	.name {
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.dir {
		color: var(--green);
		font-weight: bold;
	}

	.markdown {
		color: var(--fg);
	}

	.file {
		color: var(--grey2);
	}
</style>
