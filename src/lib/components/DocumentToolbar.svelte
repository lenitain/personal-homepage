<script lang="ts">
	/**
	 * 文档工具条：在文档内查找、调字号。
	 *
	 * 纯展示 —— 全部状态由 DocumentView 持有并通过回调上下传。
	 * 高度压在 1.8em 以内，不抢正文。
	 *
	 * 曾经这里还有页码位和「适应宽度」那套（pdf 才有的概念），随着 pdf 出局一起没了：
	 * 正文是真 DOM 文本，没有「页」，缩放就是字号。
	 */
	let {
		query = $bindable(''),
		matchLabel = '',
		onFind,
		onZoom
	}: {
		query: string;
		matchLabel: string;
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
	<label class="search-field">
		<span class="search-icon" aria-hidden="true">⌕</span>
		<input
			class="search"
			type="search"
			bind:value={query}
			onkeydown={handleSearchKeydown}
			placeholder="search"
			aria-label="在文档内查找"
			spellcheck="false"
		/>
	</label>
	<span class="matches" aria-live="polite">{matchLabel}</span>

	<span class="spacer"></span>

	<button type="button" title="缩小" aria-label="缩小" onclick={() => onZoom('out')}>−</button>
	<button type="button" title="放大" aria-label="放大" onclick={() => onZoom('in')}>+</button>
	<!-- ↺ 而不是 ⤢：复位是「回到默认」，⤢ 读起来像「放大」 -->
	<button type="button" title="恢复默认字号" aria-label="恢复默认字号" onclick={() => onZoom('fit')}
		>↺</button
	>
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

	/* 做成一眼就能认出是输入框的样子：只有一条下划线的话，
	   手写体会让它读起来像一句正文（踩过这个坑） */
	.search-field {
		display: flex;
		align-items: center;
		gap: 0.3em;
		width: 14em;
		min-width: 6em;
		padding: 0 0.4em;
		background: var(--bg2);
		border: 1px solid var(--bg4);
		border-radius: 2px;
	}

	.search-field:focus-within {
		border-color: var(--blue);
	}

	.search-icon {
		color: var(--grey1);
		flex-shrink: 0;
	}

	.search {
		flex: 1;
		min-width: 0;
		border: none;
		background: transparent;
		color: var(--fg);
		font: inherit;
		padding: 0;
	}

	.search:focus {
		outline: none;
	}

	.search::placeholder {
		color: var(--grey1);
	}

	.matches {
		color: var(--grey1);
		flex-shrink: 0;
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
