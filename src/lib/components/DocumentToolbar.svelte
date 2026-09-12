<script lang="ts">
	/**
	 * 文档工具条：在文档内查找、缩放、页码。
	 *
	 * 纯展示 —— 不知道 pdf.js 的存在，全部状态由 DocumentViewer 持有并通过回调上下传。
	 * 高度压在 1.8em 以内，不抢正文。
	 */
	let {
		query = $bindable(''),
		matchLabel = '',
		pageNumber = 1,
		pageCount = 1,
		onFind,
		onZoom
	}: {
		query: string;
		matchLabel: string;
		pageNumber: number;
		pageCount: number;
		onFind: (direction: 'next' | 'previous') => void;
		onZoom: (direction: 'in' | 'out' | 'fit') => void;
	} = $props();

	function handleSearchKeydown(event: KeyboardEvent) {
		if (event.key !== 'Enter') return;
		event.preventDefault();
		onFind(event.shiftKey ? 'previous' : 'next');
	}
</script>

<div class="document-toolbar">
	<input
		class="search"
		type="search"
		bind:value={query}
		onkeydown={handleSearchKeydown}
		placeholder="find in document"
		aria-label="在文档内查找"
		spellcheck="false"
	/>
	<span class="matches" aria-live="polite">{matchLabel}</span>

	<span class="spacer"></span>

	<button type="button" title="缩小" aria-label="缩小" onclick={() => onZoom('out')}>−</button>
	<button type="button" title="放大" aria-label="放大" onclick={() => onZoom('in')}>+</button>
	<button type="button" title="适应宽度" aria-label="适应宽度" onclick={() => onZoom('fit')}
		>⤢</button
	>
	<span class="pages">{pageNumber} / {pageCount}</span>
</div>

<style>
	.document-toolbar {
		display: flex;
		align-items: center;
		gap: 0.5em;
		height: 1.8em;
		padding: 0 0.6em;
		background: var(--bg1);
		border-bottom: 1px solid var(--bg4);
		font-size: 0.9em;
		white-space: nowrap;
	}

	.search {
		width: 14em;
		min-width: 6em;
		border: none;
		border-bottom: 1px solid var(--bg4);
		background: transparent;
		color: var(--fg);
		font: inherit;
		padding: 0 0.2em;
	}

	.search:focus {
		outline: none;
		border-bottom-color: var(--blue);
	}

	.search::placeholder {
		color: var(--grey1);
	}

	.matches,
	.pages {
		color: var(--grey1);
		flex-shrink: 0;
	}

	.pages {
		color: var(--blue);
	}

	.spacer {
		flex: 1;
	}

	button {
		border: none;
		background: transparent;
		color: var(--grey1);
		font: inherit;
		line-height: 1;
		padding: 0 0.3em;
		cursor: pointer;
	}

	button:hover {
		color: var(--fg);
		background: var(--bg2);
	}
</style>
