<script lang="ts">
	import { marked } from 'marked';
	import type { FsEntry } from '$lib/types';
	import FileList from './FileList.svelte';

	let { entry }: { entry: FsEntry | null } = $props();

	let html = $derived(
		entry?.content ? (marked.parse(entry.content) as string) : ''
	);
</script>

<div class="content-pane">
	{#if entry?.type === 'dir' && entry.children?.length}
		<FileList entries={entry.children} />
	{:else if entry?.type === 'file' && html}
		<article>{@html html}</article>
	{:else if entry?.type === 'dir'}
		<div class="empty">empty directory</div>
	{:else}
		<div class="empty">select a file to preview</div>
	{/if}
</div>

<style>
	.content-pane {
		flex: 1;
		overflow-y: auto;
		background: var(--bg0);
		padding: 0 0.8em;
	}

	.empty {
		color: var(--grey1);
		padding: 0.6em;
	}

	/* Markdown content styling */
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
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
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
</style>
