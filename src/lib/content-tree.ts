import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { previewKindOf } from './preview-kind';
import type { FsEntry } from './types';

/**
 * 递归读取 content/，产出整棵文件树。
 *
 * 只收可预览的三种文件（`.md` / `.typ` / `.pdf`）；点号开头的文件与目录一律跳过 ——
 * typst 编译用的 wrapper 就是隐藏文件，不该出现在访客眼前。递归完一个可预览文件
 * 都没有的目录会被整支丢掉，免得侧边栏里出现点了没反应的文件夹。每一层都排成
 * 「目录在前、文件在后，各自按名称字母序」，因为 readdir 自己的顺序不保证。
 *
 * 只有 markdown 内联 `content`：typst 要现编译、pdf 是二进制，两者都走各自的 HTTP 路由，
 * 不能塞进 SSR 载荷。
 */
export async function readContentTree(contentDir: string): Promise<FsEntry[]> {
	return readDirectoryEntries(contentDir, '');
}

async function readDirectoryEntries(dirPath: string, parentPath: string): Promise<FsEntry[]> {
	const dirents = await readdir(dirPath, { withFileTypes: true });
	const directories: FsEntry[] = [];
	const files: FsEntry[] = [];

	for (const dirent of dirents) {
		if (dirent.name.startsWith('.')) continue;

		const entryPath = parentPath ? `${parentPath}/${dirent.name}` : dirent.name;

		if (dirent.isDirectory()) {
			const children = await readDirectoryEntries(join(dirPath, dirent.name), entryPath);
			if (children.length > 0) {
				directories.push({ path: entryPath, name: dirent.name, type: 'dir', children });
			}
			continue;
		}

		const kind = previewKindOf(dirent.name);
		if (!kind) continue;

		const fullPath = join(dirPath, dirent.name);
		const stats = await stat(fullPath);
		const content = kind === 'markdown' ? await readFile(fullPath, 'utf-8') : undefined;

		files.push({
			path: entryPath,
			name: dirent.name,
			type: 'file',
			content,
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
