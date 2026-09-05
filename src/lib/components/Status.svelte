<script lang="ts">
	import type { FsEntry } from '$lib/types';

	let { entry, parentCount }: { entry: FsEntry | null; parentCount: number } =
		$props();

	function permissions(entry: FsEntry): string {
		if (entry.type === 'dir') return 'dr-xr-x';
		return '-rw-r--r--';
	}

	function size(entry: FsEntry): string {
		if (entry.type === 'dir') {
			const count = entry.children?.length ?? 0;
			return `${count} item${count !== 1 ? 's' : ''}`;
		}
		const bytes = (entry.content?.length ?? 0);
		if (bytes < 1024) return `${bytes}B`;
		return `${(bytes / 1024).toFixed(1)}K`;
	}
	function formatMtime(mtime?: string): string {
		if (!mtime) return '';
		const d = new Date(mtime);
		const pad = (n: number) => String(n).padStart(2, '0');
		return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
	}
</script>

<footer>
	{#if entry}
		<span class="perms">{permissions(entry)}</span>
		<span class="size">{size(entry)}</span>
		<span class="meta">
			{#if entry.type === 'dir'}
				directory
			{:else}
				{entry.name.split('.').pop()} file
			{/if}
		</span>
		{#if entry.type === 'file' && entry.mtime}
			<span class="mtime">{formatMtime(entry.mtime)}</span>
		{/if}
	{:else}
		<span class="perms">--------</span>
		<span class="size">-</span>
	{/if}
	<span class="count">{parentCount} items</span>
</footer>

<style>
	footer {
		display: flex;
		align-items: center;
		gap: 1.5em;
		height: 1.6em;
		padding: 0 0.8em;
		background: var(--bg1);
		color: var(--grey1);
		border-top: 1px solid var(--bg4);
		font-size: 0.9em;
	}

	.perms {
		color: var(--grey0);
	}

	.size {
		color: var(--yellow);
	}

	.meta {
		color: var(--grey1);
	}

	.count {
		margin-left: auto;
		color: var(--grey0);
	}

	.mtime {
		color: var(--blue);
	}
</style>
