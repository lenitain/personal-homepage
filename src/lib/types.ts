export interface FsEntry {
	name: string;
	type: 'dir' | 'file';
	children?: FsEntry[];
	content?: string;
	mtime?: string;
}
