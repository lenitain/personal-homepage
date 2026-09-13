import { execFile } from 'node:child_process';

/** 渲染超时。HTML 导出没有排版和字体嵌入，正常是几毫秒，留足余量给首次调用。 */
const RENDER_TIMEOUT_MS = 10_000;

export type TypstRenderResult =
	| { ok: true; html: string; diagnostics: string[] }
	| { ok: false; diagnostics: string[] };

export interface TypstRenderRequest {
	/** content/ 的绝对路径。 */
	contentDir: string;
	/** 相对 content/ 的 .typ 路径，例如 `cv.typ` 或 `about/cv.typ`。 */
	documentPath: string;
}

/**
 * 把一篇 .typ 渲染成 HTML 片段，供右栏直接当正文显示。
 *
 * 关键取舍：**输出走 HTML 而不是 PDF**。typst 的两种导出意图完全不同 ——
 * HTML 导出交出**结构**（标题、列表、表格、图片、链接、行内标记），丢弃二维摆放
 * （grid / place / align / stack / rect / line / columns / v）；PDF 导出交出**视觉**，
 * 什么都能摆，但没有语义，浏览器不认，得靠一整套 pdf.js 才能显示。
 *
 * 本站是网页，正文最终一定是 HTML，所以选结构。代价是摆放要按导出目标分流
 * （见 content/cv.typ 里的 `site-columns`），收益是：正文是可选、可搜、可重排的真
 * 文本，粉笔风格由站点样式表统一施加，不需要任何画布后处理。
 *
 * 不缓存：实测渲染 ~6ms，比读一遍源文件还便宜，而调用方（readContentTree）本来
 * 就是每次请求都跑、每次都读全部 markdown 源文件。缓存只会带来失效逻辑的复杂度。
 *
 * 失败不抛异常，返回原始诊断（一行式、带源位置），交给调用方决定怎么显示。
 */
export async function renderTypstDocument(
	request: TypstRenderRequest
): Promise<TypstRenderResult> {
	const { contentDir, documentPath } = request;

	try {
		// 输出到 stdout（`-`）：HTML 导出不需要落盘，也就不用临时目录。
		const { stdout, stderr } = await runTypst(
			[
				'compile',
				'--features',
				'html',
				'--format',
				'html',
				'--root',
				'.',
				'--diagnostic-format',
				'short',
				documentPath,
				'-'
			],
			contentDir
		);

		return {
			ok: true,
			html: extractBody(stdout),
			// HTML 导出目前是实验特性，每次都会报一条总提示。它是既知的、无法消除的，
			// 不该出现在用户眼前，所以滤掉；其余诊断照常上报。
			diagnostics: cleanDiagnostics(stderr)
		};
	} catch (error) {
		return { ok: false, diagnostics: describeFailure(error) };
	}
}

/** 跑一次 typst，失败时把 stdout / stderr 一并挂到错误对象上，供诊断清洗使用。 */
function runTypst(args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
	return new Promise((resolvePromise, rejectPromise) => {
		execFile(
			'typst',
			args,
			{ cwd, timeout: RENDER_TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024 },
			(error, stdout, stderr) => {
				if (error) {
					rejectPromise(Object.assign(error, { stdout, stderr }));
					return;
				}
				resolvePromise({ stdout, stderr });
			}
		);
	});
}

/**
 * 从完整 HTML 文档里取出 `<body>` 内容。
 *
 * typst 只会输出自包含的完整文档（官方说输出片段是后续计划），而我们只要正文 ——
 * 外面的 `<html>` / `<head>` 由本站自己管，否则一份文档就能改掉整页的 head。
 */
function extractBody(document: string): string {
	const open = document.indexOf('<body>');
	if (open === -1) return document;
	const close = document.lastIndexOf('</body>');
	if (close === -1 || close < open) return document.slice(open + '<body>'.length);
	return document.slice(open + '<body>'.length, close);
}

/** 去掉那条每次都会出现的实验特性提示，其余诊断原样保留。 */
function cleanDiagnostics(stderr: string): string[] {
	return stderr
		.split('\n')
		.map((line) => line.trimEnd())
		.filter((line) => line.length > 0 && !line.startsWith('warning: html export is under active development'))
		.map((line) => line.trim());
}

function describeFailure(error: unknown): string[] {
	const failure = error as { killed?: boolean; stderr?: string; stdout?: string; message?: string };

	if (failure?.killed) {
		return [`typst 渲染超时（${RENDER_TIMEOUT_MS / 1000} 秒），已中止`];
	}

	const raw = `${failure?.stderr ?? ''}${failure?.stdout ?? ''}`.trim();
	const lines = cleanDiagnostics(raw);
	if (lines.length === 0) {
		return [`typst 渲染失败：${failure?.message ?? '未知错误'}`];
	}
	return lines;
}
