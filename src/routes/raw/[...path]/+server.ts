import { readFile, stat } from 'node:fs/promises';
import { basename } from 'node:path';
import type { RequestHandler } from '@sveltejs/kit';
import { CONTENT_DIR } from '$lib/content-dir.server';
import { resolveContentPath } from '$lib/content-path';

/**
 * 原样吐出 content/ 下 pdf 的字节，供右栏的 pdf.js 取用。
 *
 * 白名单**只有 .pdf**；路径穿越由 resolveContentPath 挡掉，挡不住的一律 404。
 * `etag` 交给 SvelteKit 处理条件请求 —— 它见到 200 + etag 就会自己比对 `if-none-match`
 * 并回 304，不用在这里手写。
 */
export const GET: RequestHandler = async ({ params, setHeaders }) => {
	const filePath = resolveContentPath({
		contentDir: CONTENT_DIR,
		urlPath: params.path ?? '',
		allowedExtensions: ['.pdf']
	});
	if (!filePath) return new Response('not found', { status: 404 });

	const [pdf, stats] = await Promise.all([
		readFile(filePath).catch(() => null),
		stat(filePath).catch(() => null)
	]);
	if (!pdf || !stats) return new Response('not found', { status: 404 });

	const downloadName = basename(filePath).replace(/["\\\r\n]/g, '_');

	setHeaders({
		'content-type': 'application/pdf',
		'content-length': String(stats.size),
		'content-disposition': `inline; filename="${downloadName}"`,
		'x-content-type-options': 'nosniff',
		'cache-control': 'no-cache',
		etag: `"${stats.mtimeMs.toString(36)}-${stats.size.toString(36)}"`
	});

	// 复制成普通 Uint8Array：Node 的 Buffer 在类型上不满足 DOM 的 BodyInit
	return new Response(new Uint8Array(pdf));
};
