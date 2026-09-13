<script lang="ts">
	import DocumentViewer from './DocumentViewer.svelte';
	import MarkdownView from './MarkdownView.svelte';
	import { previewKindOf } from '$lib/preview-kind';
	import type { FsEntry } from '$lib/types';

	let { entry }: { entry: FsEntry | null } = $props();

	let kind = $derived(entry ? previewKindOf(entry.name) : null);

	/** 每段单独编码：文件名里可能有空格或 `#`，整串 encodeURI 处理不了它们。 */
	function documentUrl(prefix: string, path: string): string {
		const encoded = path.split('/').map(encodeURIComponent).join('/');
		return `${prefix}/${encoded}`;
	}
</script>

<!--
	三种格式各自一个视图组件，但共用同一个 DocumentToolbar（`tone` 与缩放/查找的语义
	由各自的视图负责）。markdown 用 MarkdownView，typst / pdf 都走 DocumentViewer。
-->
{#if entry && kind === 'typst'}
	<DocumentViewer url={documentUrl('/typst', entry.path)} tone="chalk" title={entry.name} />
{:else if entry && kind === 'pdf'}
	<DocumentViewer url={documentUrl('/raw', entry.path)} tone="invert" title={entry.name} />
{:else if entry && kind === 'markdown' && entry.content}
	<MarkdownView source={entry.content} />
{:else}
	<div class="content-pane">
		<div class="empty">select a file to preview</div>
	</div>
{/if}

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
</style>
