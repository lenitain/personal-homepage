import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { PageServerLoad } from './$types';
import type { FsEntry } from '$lib/types';

const CONTENT_DIR = join(process.cwd(), 'content');

async function readDir(dirPath: string): Promise<FsEntry[]> {
	const entries = await readdir(dirPath, { withFileTypes: true });
	const result: FsEntry[] = [];

	for (const entry of entries) {
		const fullPath = join(dirPath, entry.name);
		if (entry.isDirectory()) {
			result.push({
				name: entry.name,
				type: 'dir',
				children: await readDir(fullPath)
			});
		} else if (entry.name.endsWith('.md')) {
			const content = await readFile(fullPath, 'utf-8');
			const { mtime } = await stat(fullPath);
			result.push({
				name: entry.name,
				type: 'file',
				content,
				mtime: mtime.toISOString()
			});
		}
	}

	return result;
}

export const load: PageServerLoad = async () => {
	const tree = await readDir(CONTENT_DIR);
	const readmeIndex = tree.findIndex((e) => e.name === 'readme.md');
	return {
		tree: {
			name: '~',
			type: 'dir' as const,
			children: tree
		},
		initialIndex: readmeIndex >= 0 ? readmeIndex : 0
	};
};
