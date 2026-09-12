import { stat } from 'node:fs/promises';
import { json, type RequestHandler } from '@sveltejs/kit';
import { CONTENT_DIR } from '$lib/content-dir.server';
import { resolveContentPath } from '$lib/content-path';
import { compileTypstDocument } from '$lib/typst-compile';

/**
 * 编译 content/ 下的 .typ 并吐出 pdf 字节，供右栏的 pdf.js 取用。
 *
 * 一个 URL 两种结果：编译成功给 `application/pdf`（`etag` 是依赖哈希，SvelteKit
 * 拿它处理 304），编译失败给 `422` + 一行式诊断，客户端据此渲染报错面板。
 * 白名单只有 .typ；文件不存在、扩展名不符、路径穿越统一 404。
 */
export const GET: RequestHandler = async ({ params, setHeaders }) => {
	const documentPath = params.path ?? '';
	const filePath = resolveContentPath({
		contentDir: CONTENT_DIR,
		urlPath: documentPath,
		allowedExtensions: ['.typ']
	});
	if (!filePath) return new Response('not found', { status: 404 });
	if (!(await stat(filePath).catch(() => null))) {
		return new Response('not found', { status: 404 });
	}

	const result = await compileTypstDocument({ contentDir: CONTENT_DIR, documentPath });
	if (!result.ok) {
		return json({ error: 'typst 编译失败', diagnostics: result.diagnostics }, { status: 422 });
	}

	setHeaders({
		'content-type': 'application/pdf',
		'content-length': String(result.pdf.byteLength),
		'cache-control': 'no-cache',
		etag: `"${result.hash}"`
	});

	// 复制成普通 Uint8Array：Node 的 Buffer 在类型上不满足 DOM 的 BodyInit
	return new Response(new Uint8Array(result.pdf));
};
