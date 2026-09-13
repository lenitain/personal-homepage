<script lang="ts">
	import { onMount } from 'svelte';
	// 用 legacy 构建：modern 构建直接用了 `Map.prototype.getOrInsertComputed` 这类新 API，
	// 旧一点的浏览器（Safari、Firefox ESR 等）没有它，整个文档就打不开 —— 报
	// "getOrInsertComputed is not a function"。legacy 里带 core-js 补丁，
	// 代价只有约 +60KB 主包 / +50KB worker。
	import workerUrl from 'pdfjs-dist/legacy/build/pdf.worker.min.mjs?url';
	import DocumentToolbar from './DocumentToolbar.svelte';
	import { CHALK_PALETTE } from '$lib/chalk-palette';
	import { imageRectsFromOperatorList, type PageRect } from '$lib/pdf-image-rects';

	type CoreModule = typeof import('pdfjs-dist/legacy/build/pdf.mjs');
	type ViewerLayerModule = typeof import('pdfjs-dist/web/pdf_viewer.mjs');
	type PdfJsViewer = InstanceType<ViewerLayerModule['PDFViewer']>;
	type PdfEventBus = InstanceType<ViewerLayerModule['EventBus']>;
	type PdfDocument = Awaited<ReturnType<CoreModule['getDocument']>['promise']>;

	/**
	 * 右栏的文档视图：把一份 pdf（现成的，或 typst 现编译的）交给 pdf.js 的 viewer 层渲染。
	 *
	 * `tone` 决定颜色从哪来：
	 * - `chalk`  —— typst 编译时已经烘进粉笔主题，这里只补颗粒
	 * - `invert` —— 现成 pdf 是白底，在 canvas 像素上反色，**并把照片豁免掉**
	 *
	 * 刻意不自己实现的三件事：文字层与链接层交给 pdf.js，可见区懒渲染交给 viewer 自带的缓冲，
	 * 文档内查找交给 `PDFFindController`。浏览器自带的 Ctrl+F 不拦截，照常在文字层上匹配。
	 */
	let {
		url,
		tone,
		title
	}: {
		url: string;
		tone: 'chalk' | 'invert';
		title: string;
	} = $props();

	/** 画布上的颜色变换。元素级滤镜做不到「图片豁免」，所以放在像素上做。 */
	const PDF_TONE_FILTER = 'invert(1) hue-rotate(180deg) sepia(0.3) saturate(1.3) brightness(1.05)';

	/** 渲染前先预取这么多页的图像矩形，好让 `pagerendered` 的处理保持同步、没有竞态。 */
	const RECT_PREFETCH_RADIUS = 2;

	let scrollHost = $state<HTMLDivElement | null>(null);
	let viewerSurface = $state<HTMLDivElement | null>(null);
	let loading = $state(true);
	let failure = $state('');
	let diagnostics = $state<string[]>([]);
	/** `ctx.filter` 不可用（Safari）时退回元素级反色 —— 代价是照片也会被反色。 */
	let toneFallsBackToCss = $state(false);

	let query = $state('');
	let matchLabel = $state('');
	let pageNumber = $state(1);
	let pageCount = $state(1);

	let pdfViewer: PdfJsViewer | null = null;
	let eventBus: PdfEventBus | null = null;
	let pdfDocument: PdfDocument | null = null;
	let operatorListOps: CoreModule['OPS'] | null = null;
	/** 每页的图像矩形（视口 scale 1 的坐标）与那一页的宽度，换算到 canvas 像素时要用。 */
	const imageRectCache = new Map<number, { rects: PageRect[]; viewportWidth: number }>();
	/** 每张 canvas 最近一次渲染的时间戳，用来判断异步回来的变换还算不算数。 */
	const latestRenderStamp = new Map<HTMLCanvasElement, number>();
	/** 计数刷新用的事务去抖计时器（组件级：MutationObserver 与派发搜索都要用它）。 */
	let labelRefreshTimer: ReturnType<typeof setTimeout> | null = null;

	onMount(() => {
		let disposed = false;
		let loadingTask: ReturnType<CoreModule['getDocument']> | null = null;
		let resizeObserver: ResizeObserver | null = null;
		let labelObserver: MutationObserver | null = null;

		async function boot() {
			const response = await fetch(url);
			if (!response.ok) {
				const payload = (await response.json().catch(() => null)) as {
					error?: string;
					diagnostics?: string[];
				} | null;
				if (payload?.diagnostics?.length) {
					diagnostics = payload.diagnostics;
				} else {
					failure = payload?.error ?? `取不到文档（HTTP ${response.status}）`;
				}
				loading = false;
				return;
			}

			const data = new Uint8Array(await response.arrayBuffer());
			if (disposed) return;

			// pdf.js 只能在客户端初始化，而且顺序有讲究：
			// viewer 层（web/pdf_viewer.mjs）是个独立 bundle，它从 `globalThis.pdfjsLib` 上
			// 解构整套 API（源码里就是 `const {...} = globalThis.pdfjsLib`），所以必须先把
			// 核心模块挂到全局，再 import 它 —— 反了就是 "AbortException of undefined"。
			const core = await import('pdfjs-dist/legacy/build/pdf.mjs');
			if (disposed) return;
			(globalThis as unknown as { pdfjsLib: unknown }).pdfjsLib = core;

			// CSS 与 viewer 层按需拉，只有真打开文档的访客付这份钱
			const [viewerLayer] = await Promise.all([
				import('pdfjs-dist/web/pdf_viewer.mjs'),
				import('pdfjs-dist/web/pdf_viewer.css')
			]);
			if (disposed) return;

			core.GlobalWorkerOptions.workerSrc = workerUrl;
			operatorListOps = core.OPS;

			eventBus = new viewerLayer.EventBus();
			const linkService = new viewerLayer.PDFLinkService({
				eventBus,
				externalLinkTarget: viewerLayer.LinkTarget.BLANK
			});
			const findController = new viewerLayer.PDFFindController({ linkService, eventBus });

			loadingTask = core.getDocument({
				data,
				// 决策 11：CJK 的 CMap 与标准字体自托管，不然非嵌入字体的 pdf 会缺字
				cMapUrl: '/pdfjs/cmaps/',
				cMapPacked: true,
				standardFontDataUrl: '/pdfjs/standard_fonts/'
			});
			pdfDocument = await loadingTask.promise;
			if (disposed) return;

			// viewer 层的类型要求 container 一定存在（它还要取 firstElementChild），挂不上就别硬来
			if (!scrollHost || !viewerSurface) throw new Error('文档容器没有挂载');

			pdfViewer = new viewerLayer.PDFViewer({
				container: scrollHost,
				viewer: viewerSurface,
				eventBus,
				linkService,
				findController,
				// 不要 pdf.js 那套「一张纸」的边：白白一圈衬在黑板前很跳
				removePageBorders: true
			});
			linkService.setViewer(pdfViewer);

			// 监听要在 setDocument 之前挂上，否则会漏掉 pagesinit
			pageCount = pdfDocument.numPages;
			eventBus.on('pagesinit', () => {
				if (!pdfViewer) return;
				pdfViewer.currentScaleValue = 'page-width';
				prefetchImageRects(1, pageCount);
			});
			eventBus.on('pagechanging', (event: { pageNumber: number }) => {
				pageNumber = event.pageNumber;
				prefetchImageRects(event.pageNumber - RECT_PREFETCH_RADIUS, event.pageNumber + RECT_PREFETCH_RADIUS);
			});
			eventBus.on('updatefindmatchescount', () => scheduleMatchLabelRefresh());
			eventBus.on('pagerendered', (event: PageRenderedEvent) => {
				void applyToneToPage(event);
			});

			linkService.setDocument(pdfDocument);
			findController.setDocument(pdfDocument);
			pdfViewer.setDocument(pdfDocument);

			// 侧栏开合是宽度动画，页面要跟着重新 fit-width
			if (scrollHost) {
				resizeObserver = new ResizeObserver(() => pdfViewer?.update());
				resizeObserver.observe(scrollHost);

				// 高亮是 pdf.js 自己往 DOM 里加/删的，盯着它算计数最可靠：
				// 固定延时会在「搜不存在的词」时抢在清高亮之前跑出旧数字
				labelObserver = new MutationObserver(() => scheduleMatchLabelRefresh());
				labelObserver.observe(scrollHost, {
					childList: true,
					subtree: true,
					attributes: true,
					attributeFilter: ['class']
				});
			}

			loading = false;
		}

		void boot().catch((error: unknown) => {
			if (disposed) return;
			failure = `文档加载失败：${error instanceof Error ? error.message : String(error)}`;
			loading = false;
		});

		return () => {
			disposed = true;
			resizeObserver?.disconnect();
			labelObserver?.disconnect();
			if (labelRefreshTimer) clearTimeout(labelRefreshTimer);
			latestRenderStamp.clear();
			imageRectCache.clear();
			pdfDocument = null;
			// loadingTask.destroy() 会连 worker 一起收掉，不需要再去碰 pdfDocument
			void loadingTask?.destroy();
		};
	});

	/** 后台把一段页的图像矩形算出来，让真正渲染时能同步处理。 */
	function prefetchImageRects(from: number, to: number) {
		for (let page = Math.max(1, from); page <= Math.min(to, pageCount); page++) {
			void imageRectsForPage(page).catch(() => undefined);
		}
	}

	/**
	 * 给已经画好的页面做颜色变换，图像矩形用变换前的原像素盖回去。
	 *
	 * 竞态：`pagerendered` 之后我们可能还要等算子列表，而 pdf.js 在缩放时会把同一张 canvas
	 * 重画一遍 —— 那时对旧像素做变换、再被新渲染处理一次，就会反色两次变成白页。
	 * 所以：矩形已缓存就**同步**处理；没缓存才异步，并在回来时核对 canvas 的渲染时间戳。
	 */
	async function applyToneToPage(event: PageRenderedEvent) {
		const canvas = event.source?.canvas;
		if (tone !== 'invert' || !canvas) return;

		latestRenderStamp.set(canvas, event.timestamp);

		const cached = imageRectCache.get(event.pageNumber);
		if (cached) {
			applyInvertWithImageExemption(canvas, scaleRects(cached, canvas));
			return;
		}

		try {
			const entry = await imageRectsForPage(event.pageNumber);
			if (latestRenderStamp.get(canvas) !== event.timestamp) return;
			applyInvertWithImageExemption(canvas, scaleRects(entry, canvas));
		} catch {
			// 算子列表解析不出来就退回元素级反色：宁可照片变负片，也不能让页面渲染不出来
			toneFallsBackToCss = true;
		}
	}

	function scaleRects(
		entry: { rects: PageRect[]; viewportWidth: number },
		canvas: HTMLCanvasElement
	): PageRect[] {
		const factor = entry.viewportWidth > 0 ? canvas.width / entry.viewportWidth : 1;
		if (factor === 1) return entry.rects;
		return entry.rects.map((rect) => ({
			x: rect.x * factor,
			y: rect.y * factor,
			width: rect.width * factor,
			height: rect.height * factor
		}));
	}

	/** 取某一页的图像矩形（视口 scale 1 坐标），按页缓存。 */
	async function imageRectsForPage(
		targetPageNumber: number
	): Promise<{ rects: PageRect[]; viewportWidth: number }> {
		const cached = imageRectCache.get(targetPageNumber);
		if (cached) return cached;
		if (!pdfDocument || !operatorListOps) return { rects: [], viewportWidth: 1 };

		const page = await pdfDocument.getPage(targetPageNumber);
		const viewport = page.getViewport({ scale: 1 });
		const { fnArray, argsArray } = await page.getOperatorList();
		const entry = {
			rects: imageRectsFromOperatorList({
				fnArray,
				argsArray,
				viewportTransform: viewport.transform,
				ops: {
					save: operatorListOps.save,
					restore: operatorListOps.restore,
					transform: operatorListOps.transform,
					paintImageXObject: operatorListOps.paintImageXObject,
					paintInlineImageXObject: operatorListOps.paintInlineImageXObject
				}
			}),
			viewportWidth: viewport.width
		};
		imageRectCache.set(targetPageNumber, entry);
		return entry;
	}

	/**
	 * 在 canvas 像素上反色，图像矩形用反色前的原像素盖回去。
	 * 返回 false 表示这个浏览器不支持 `ctx.filter`（如 Safari），调用方退回元素级反色。
	 */
	function applyInvertWithImageExemption(canvas: HTMLCanvasElement, rects: PageRect[]): boolean {
		const context = canvas.getContext('2d');
		if (!context || typeof context.filter !== 'string') return false;

		const { width, height } = canvas;
		if (width === 0 || height === 0) return false;

		const snapshot = document.createElement('canvas');
		snapshot.width = width;
		snapshot.height = height;
		const snapshotContext = snapshot.getContext('2d');
		if (!snapshotContext) return false;
		snapshotContext.drawImage(canvas, 0, 0);

		const toned = document.createElement('canvas');
		toned.width = width;
		toned.height = height;
		const tonedContext = toned.getContext('2d');
		if (!tonedContext) return false;

		tonedContext.filter = PDF_TONE_FILTER;
		tonedContext.drawImage(canvas, 0, 0);
		tonedContext.filter = 'none';

		// 反色后的页底是纯黑，跟黑板的板色差一截。lighten 取每通道较大值：
		// 黑底被抬到板色，而正文比板色亮，原样保留。
		tonedContext.globalCompositeOperation = 'lighten';
		tonedContext.fillStyle = CHALK_PALETTE.board;
		tonedContext.fillRect(0, 0, width, height);
		tonedContext.globalCompositeOperation = 'source-over';

		for (const rect of rects) {
			const x = Math.max(0, Math.floor(rect.x));
			const y = Math.max(0, Math.floor(rect.y));
			const w = Math.min(width - x, Math.ceil(rect.width));
			const h = Math.min(height - y, Math.ceil(rect.height));
			if (w <= 0 || h <= 0) continue;
			tonedContext.drawImage(snapshot, x, y, w, h, x, y, w, h);
		}

		context.clearRect(0, 0, width, height);
		context.drawImage(toned, 0, 0);
		return true;
	}

	function find(direction: 'next' | 'previous') {
		// pdf.js 认的事件类型是 'again'（源码里的分支就是 type === "again"），
		// 写成 'findagain' 会落进兜底分支：能跳，但高亮与计数不按预期刷新
		dispatchFind('again', direction === 'previous');
	}

	/** 输入变化即开搜；防抖交给 pdf.js 自己（`#onFind` 对新搜索有延迟调度）。 */
	$effect(() => {
		const value = query;
		if (!eventBus) return;
		eventBus.dispatch('find', {
			source: eventBus,
			type: '',
			query: value,
			caseSensitive: false,
			entireWord: false,
			matchDiacritics: false,
			highlightAll: true,
			findPrevious: false
		});
		scheduleMatchLabelRefresh();
	});

	function dispatchFind(type: string, findPrevious: boolean) {
		eventBus?.dispatch('find', {
			source: eventBus,
			type,
			query,
			caseSensitive: false,
			entireWord: false,
			matchDiacritics: false,
			highlightAll: true,
			findPrevious
		});
		scheduleMatchLabelRefresh();
	}

	/**
	 * 从 DOM 现算「第几个 / 共几个」。
	 *
	 * 不用 `updatefindmatchescount` 的载荷：pdf.js 在 PENDING 阶段就派发它，那时
	 * `_selected` 还是推进前的值，所以按它显示会永远慢一步（实测回车后选中已经跳到
	 * 第二个，载荷里却还是 1）。改成数高亮元素、找带 `selected` 的那个，跟用户看到的一致。
	 */
	function scheduleMatchLabelRefresh() {
		if (labelRefreshTimer) clearTimeout(labelRefreshTimer);
		labelRefreshTimer = setTimeout(refreshMatchLabel, 60);
	}

	function refreshMatchLabel() {
		labelRefreshTimer = null;
		const highlights = scrollHost?.querySelectorAll('.textLayer .highlight') ?? [];
		const total = highlights.length;
		if (total === 0) {
			matchLabel = query ? '0 / 0' : '';
			return;
		}
		const selected = Array.from(highlights).findIndex((element) =>
			element.classList.contains('selected')
		);
		matchLabel = `${selected + 1} / ${total}`;
	}

	function zoom(direction: 'in' | 'out' | 'fit') {
		if (!pdfViewer) return;
		if (direction === 'fit') {
			pdfViewer.currentScaleValue = 'page-width';
			return;
		}
		const current = pdfViewer.currentScale || 1;
		pdfViewer.currentScale = direction === 'in' ? current * 1.2 : current / 1.2;
	}

	interface PageRenderedEvent {
		pageNumber: number;
		timestamp: number;
		source?: { canvas?: HTMLCanvasElement };
	}
</script>

{#if loading}
	<div class="notice">compiling / loading…</div>
{:else if diagnostics.length > 0}
	<div class="failure">
		<p>typst 编译失败</p>
		<pre>{diagnostics.join('\n')}</pre>
	</div>
{:else if failure}
	<div class="failure"><p>{failure}</p></div>
{:else}
	<DocumentToolbar
		bind:query
		{matchLabel}
		{pageNumber}
		{pageCount}
		resetTitle="适应宽度"
		onFind={find}
		onZoom={zoom}
	/>
{/if}

<div class="viewer-shell">
	<div
		class="viewer-host"
		class:css-tone-fallback={toneFallsBackToCss}
		data-tone={tone}
		bind:this={scrollHost}
	>
		<div class="pdfViewer" bind:this={viewerSurface} aria-label={title}></div>
	</div>
</div>

<style>
	/* pdf.js 的 viewer 层要求滚动容器必须是 absolute（源码里直接抛错），
	   所以外面套一层 relative 的壳，壳负责在 flex 里占位。 */
	.viewer-shell {
		position: relative;
		flex: 1;
		min-height: 0;
	}

	.viewer-host {
		position: absolute;
		inset: 0;
		overflow: auto;
		background: var(--bg0);
		/* pdf.js 给每页留了个白色纸底（`background-color: var(--page-bg-color, #fff)`），
		   它在页面缩放的分数像素边缘会漏出一圈白线。这个变量就是留给使用方覆盖的。 */
		--page-bg-color: transparent;
	}

	/* 粉笔颗粒按页套：整栏套会让大滚动区每帧重栅格化 */
	.viewer-host :global(canvas) {
		filter: url(#chalk-writing);
	}

	/* 只有像素级反色不可用时才把反色放到元素上（此时照片也会被反色） */
	.viewer-host.css-tone-fallback :global(canvas) {
		filter: invert(1) hue-rotate(180deg) sepia(0.3) saturate(1.3) brightness(1.05)
			url(#chalk-writing);
	}

	/* 文字层本身透明，选中着色得自己给 —— 页面是暗底，默认高亮对比不够 */
	.viewer-host :global(.textLayer ::selection) {
		background: color-mix(in srgb, var(--blue) 45%, transparent);
		color: transparent;
	}

	.notice,
	.failure {
		padding: 0.8em;
		color: var(--grey1);
	}

	.failure {
		color: var(--red);
	}

	.failure pre {
		margin-top: 0.4em;
		white-space: pre-wrap;
		font-family: 'Kalam', 'Patrick Hand', 'Yusei Magic', cursive;
		font-size: 0.9em;
		color: var(--orange);
	}
</style>
