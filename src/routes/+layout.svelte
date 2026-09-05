<script lang="ts">
	let { children } = $props();
</script>

<svelte:head>
	<title>/home/lenitain/</title>
</svelte:head>

{@render children()}

<style>
	:global(*) {
		margin: 0;
		padding: 0;
		box-sizing: border-box;
	}

	:global(html, body) {
		height: 100%;
		overflow: hidden;
	}

	:global(body) {
		/* Everforest Dark Medium */
		--bg_dim: #232A2E;
		--bg0: #2D353B;
		--bg1: #343F44;
		--bg2: #3D484D;
		--bg3: #475258;
		--bg4: #4F585E;
		--bg5: #56635f;

		--fg: #D3C6AA;

		--red: #E67E80;
		--orange: #E69875;
		--yellow: #DBBC7F;
		--green: #A7C080;
		--aqua: #83C092;
		--blue: #7FBBB3;
		--purple: #D699B6;

		--grey0: #7A8478;
		--grey1: #859289;
		--grey2: #9DA9A0;

		background: var(--bg0);
		color: var(--fg);
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
		font-size: 1.125rem;
	}

	/* Scrollbar styling to match everforest */
	:global(::-webkit-scrollbar) {
		width: 6px;
	}

	:global(::-webkit-scrollbar-track) {
		background: var(--bg0);
	}

	:global(::-webkit-scrollbar-thumb) {
		background: var(--bg4);
		border-radius: 3px;
	}

	:global(::-webkit-scrollbar-thumb:hover) {
		background: var(--grey1);
	}

	/* Selection color */
	:global(::selection) {
		background: var(--bg3);
		color: var(--fg);
	}
</style>
