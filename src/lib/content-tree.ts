import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { FsEntry } from './types';

/**
 * 递归读取一个 content/ 目录，产出整棵文件树。
 *
 * 只收 `.md` 文件；递归完一篇文章都没有的目录会被整支丢掉 —— 免得侧边栏里
 * 出现点了没反应的文件夹。每一层都排成「目录在前、文件在后，各自按名称字母序」，
 * 因为 readdir 自己的顺序是不保证的，排过序树才稳定。
 */
export async function readContentTree(contentDir: string): Promise<FsEntry[]> {
	return readDirectoryEntries(contentDir, '');
}

async function readDirectoryEntries(dirPath: string, parentPath: string): Promise<FsEntry[]> {
	const dirents = await readdir(dirPath, { withFileTypes: true });
	const directories: FsEntry[] = [];
	const files: FsEntry[] = [];

	for (const dirent of dirents) {
		const entryPath = parentPath ? `${parentPath}/${dirent.name}` : dirent.name;

		if (dirent.isDirectory()) {
			const children = await readDirectoryEntries(join(dirPath, dirent.name), entryPath);
			if (children.length > 0) {
				directories.push({ path: entryPath, name: dirent.name, type: 'dir', children });
			}
			continue;
		}

		if (!dirent.name.endsWith('.md')) continue;

		const fullPath = join(dirPath, dirent.name);
		const [content, stats] = await Promise.all([readFile(fullPath, 'utf-8'), stat(fullPath)]);
		files.push({
			path: entryPath,
			name: dirent.name,
			type: 'file',
			content,
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
