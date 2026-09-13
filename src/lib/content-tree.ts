import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { previewKindOf } from './preview-kind';
import { renderTypstDocument } from './typst-compile';
import type { FsEntry } from './types';

/**
 * 递归读取 content/，产出整棵文件树，并把每个可预览文件的正文一并内联。
 *
 * 只收可预览的两种文件（`.md` / `.typ`）；点号开头的文件与目录一律跳过。递归完一个
 * 可预览文件都没有的目录会被整支丢掉，免得侧边栏里出现点了没反应的文件夹。每一层
 * 都排成「目录在前、文件在后，各自按名称字母序」，因为 readdir 自己的顺序不保证。
 *
 * **正文内联是这条路的全部要点**：markdown 读源文本，typst 现渲染成 HTML 片段。
 * 两者都随 SSR 载荷一起到浏览器，于是点开任何一篇都是零请求、零引擎启动 ——
 * 渲染器就是浏览器自己。typst 渲染实测 ~6ms，比读一遍源文件还便宜，所以不做缓存。
 *
 * 渲染失败的 typst 不抛出：把诊断当正文放进去，让右栏显示错误面板。
 * 一篇写坏的文档不该让整棵树都打不开。
 */
export async function readContentTree(contentDir: string): Promise<FsEntry[]> {
	return readDirectoryEntries(contentDir, contentDir, '');
}

/**
 * `contentDir` 要一路传下来，而不是在函数里重新推导：typst 渲染必须拿到 content/ 的
 * 绝对路径当 `--root`，而且嵌套目录里的 `.typ`（`about/cv.typ`）也得能正确解析它自己的
 * 相对 `#include` / `#image`。
 */
async function readDirectoryEntries(
	contentDir: string,
	dirPath: string,
	parentPath: string
): Promise<FsEntry[]> {
	const dirents = await readdir(dirPath, { withFileTypes: true });
	const directories: FsEntry[] = [];
	const files: FsEntry[] = [];

	for (const dirent of dirents) {
		if (dirent.name.startsWith('.')) continue;

		const entryPath = parentPath ? `${parentPath}/${dirent.name}` : dirent.name;

		if (dirent.isDirectory()) {
			const children = await readDirectoryEntries(
				contentDir,
				join(dirPath, dirent.name),
				entryPath
			);
			if (children.length > 0) {
				directories.push({ path: entryPath, name: dirent.name, type: 'dir', children });
			}
			continue;
		}

		const kind = previewKindOf(dirent.name);
		if (!kind) continue;

		const fullPath = join(dirPath, dirent.name);
		const stats = await stat(fullPath);

		let content: string | undefined;
		let error: string[] | undefined;
		if (kind === 'markdown') {
			content = await readFile(fullPath, 'utf-8');
		} else {
			const rendered = await renderTypstDocument({ contentDir, documentPath: entryPath });
			if (rendered.ok) content = rendered.html;
			else error = rendered.diagnostics;
		}

		files.push({
			path: entryPath,
			name: dirent.name,
			type: 'file',
			content,
			error,
			size: stats.size,
			mtime: stats.mtime.toISOString()
		});
	}

	directories.sort(compareByName);
	files.sort(compareByName);

	return [...directories, ...files];
}

function compareByName(a: FsEntry, b: FsEntry): number {
	return a.name.localeCompare(b.name);
}
