<script lang="ts">
	import DocumentView from './DocumentView.svelte';
	import { previewKindOf } from '$lib/preview-kind';
	import type { FsEntry } from '$lib/types';

	let { entry }: { entry: FsEntry | null } = $props();

	let kind = $derived(entry ? previewKindOf(entry.name) : null);
	/** 渲染失败的 typst 只有 `error`、没有 `content`，但它仍然是一篇要打开的文档。 */
	let failed = $derived(Boolean(entry && entry.content === undefined && entry.error));
</script>

<!--
	两种格式走同一个视图：正文在服务端就已经备好了（markdown 是源文本、typst 已经渲染成
	HTML 片段），客户端不再有「取内容」这一步 —— 没有 URL、没有请求、没有加载态。
-->
{#if entry && entry.content !== undefined && kind}
	<DocumentView {kind} source={entry.content} error={entry.error} />
{:else if entry && failed}
	<DocumentView kind={kind ?? 'typst'} source="" error={entry.error} />
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
