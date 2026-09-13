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

		/*
		 * 全站唯一的字体栈。要换手写体只改这一行 —— 别处一律 font-family: var(--font-chalk)。
		 *
		 * 逐字降级，靠的是浏览器原生行为，不需要任何逻辑：
		 *   英文数字 → Kalam；Kalam 缺字 → Patrick Hand
		 *   中文     → ZCOOL KuaiLe；它缺字或加载失败 → LXGW WenKai → Ma Shan Zheng
		 *   最后     → generic
		 * 尾部不再点名任何具体字体：连三个中文字体都拿不到时，就认了系统默认。
		 */
		--font-chalk: 'Kalam', 'Patrick Hand', 'ZCOOL KuaiLe', 'LXGW WenKai', 'Ma Shan Zheng',
			cursive, sans-serif;

		background: var(--bg0);
		color: var(--fg);
		font-family: var(--font-chalk);
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
