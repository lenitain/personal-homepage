<script lang="ts">
	let { cwd }: { cwd: string } = $props();
</script>

<header>
	<span class="path">{cwd}</span>
</header>

<style>
	header {
		display: flex;
		align-items: center;
		height: 1.6em;
		padding: 0 0.8em;
		background: var(--bg1);
		color: var(--fg);
		border-bottom: 1px solid var(--bg4);
		overflow: hidden;
		white-space: nowrap;
	}
	.path {
		color: var(--green);
	}
</style>
