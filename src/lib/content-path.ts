import { isAbsolute, resolve, sep } from 'node:path';

export interface ContentPathRequest {
	/** content/ 的绝对路径。解析结果必须落在它下面。 */
	contentDir: string;
	/** URL 里那段相对路径，调用方负责解码。 */
	urlPath: string;
	/** 允许的扩展名，带点，例如 `['.pdf']`。 */
	allowedExtensions: readonly string[];
}

/**
 * 路径安全闸门 —— 把 URL 里的相对路径解析成 content/ 下的绝对路径，任何不合规都返回 null。
 *
 * 这是整个预览层唯一的安全边界，所以做成纯函数以便单测。拒绝：空路径、`..` / `.` /
 * 空段、绝对路径、反斜杠（在 Windows 上是目录分隔符）、NUL 字节、扩展名不在白名单。
 * 最后一道闸是解析结果必须以 `contentDir + 分隔符` 开头。
 *
 * 有意不做的事：不解析符号链接。content/ 是自己写的目录，链到外部的软链不拦 ——
 * 要做到那一步就得引入 fs、函数也不再是纯的。
 */
export function resolveContentPath(request: ContentPathRequest): string | null {
	const { contentDir, urlPath, allowedExtensions } = request;

	if (!urlPath) return null;
	if (urlPath.includes('\0')) return null;
	if (urlPath.includes('\\')) return null;
	if (isAbsolute(urlPath)) return null;

	const segments = urlPath.split('/');
	if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
		return null;
	}

	const dot = urlPath.lastIndexOf('.');
	if (dot === -1) return null;
	if (!allowedExtensions.includes(urlPath.slice(dot).toLowerCase())) return null;

	const fullPath = resolve(contentDir, urlPath);
	const prefix = contentDir.endsWith(sep) ? contentDir : contentDir + sep;
	if (!fullPath.startsWith(prefix)) return null;

	return fullPath;
}
