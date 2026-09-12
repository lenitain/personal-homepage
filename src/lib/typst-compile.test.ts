import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readdir, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from 'vitest';
import { compileTypstDocument } from './typst-compile';

/**
 * 这些用例真调本机的 typst。没装 typst 的机器上整组跳过，而不是整片挂掉。
 *
 * 这里不验「粉笔主题有没有生效」—— 那要看像素，属于手点验证（spec 的验证清单）；
 * 单测只锁定编译产物、诊断清洗、wrapper 清理、缓存失效这几件能稳定断言的事。
 */
const hasTypst = spawnSync('typst', ['--version']).status === 0;

/** 一页正文 + 一个被 include 的片段 + 第二页，够验「多页」和「依赖失效」。 */
const DOCUMENT_SOURCE = [
	'= Preview Test',
	'',
	'Body text',
	'',
	'#include "partial.typ"',
	'',
	'#pagebreak()',
	'',
	'= Second Page'
].join('\n');

let contentDir: string;

beforeEach(async () => {
	contentDir = await mkdtemp(join(tmpdir(), 'typst-compile-'));
});

afterEach(async () => {
	await rm(contentDir, { recursive: true, force: true });
});

async function writeFixture(relativePath: string, body: string): Promise<string> {
	const fullPath = join(contentDir, relativePath);
	await mkdir(dirname(fullPath), { recursive: true });
	await writeFile(fullPath, body, 'utf-8');
	return fullPath;
}

/** 造一份可编译的文档，返回它的相对路径。 */
async function writeDocument(relativePath = 'cv.typ'): Promise<string> {
	await writeFixture('partial.typ', 'Partial content\n');
	await writeFixture(relativePath, DOCUMENT_SOURCE);
	return relativePath;
}

/** 把 mtime 推到过去，免得同毫秒内的两次写入看起来一样。 */
async function ageFile(fullPath: string, secondsAgo: number): Promise<void> {
	const when = new Date(Date.now() - secondsAgo * 1000);
	await utimes(fullPath, when, when);
}
describe.skipIf(!hasTypst)('compileTypstDocument', () => {
	test('编译成功返回以 %PDF 开头的非空 Buffer', async () => {
		const documentPath = await writeDocument();

		const result = await compileTypstDocument({ contentDir, documentPath });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.pdf.subarray(0, 5).toString('latin1')).toBe('%PDF-');
		expect(result.pdf.byteLength).toBeGreaterThan(1000);
	});

	test('编译完把 wrapper 删干净，目录里不留隐藏文件', async () => {
		const documentPath = await writeDocument();

		await compileTypstDocument({ contentDir, documentPath });

		const names = await readdir(contentDir);
		expect(names.filter((name) => name.startsWith('.preview-'))).toEqual([]);
	});

	test('语法错误返回诊断，且诊断里不出现 wrapper 的临时文件名', async () => {
		await writeFixture('broken.typ', '= Hi\n#let x = \n');

		const result = await compileTypstDocument({ contentDir, documentPath: 'broken.typ' });

		expect(result.ok).toBe(false);
		if (result.ok) return;
		expect(result.diagnostics.join('\n')).toContain('broken.typ:2:8');
		expect(result.diagnostics.join('\n')).not.toContain('.preview-');
		// 编译失败也要把 wrapper 收干净
		expect((await readdir(contentDir)).filter((name) => name.startsWith('.preview-'))).toEqual([]);
	});

	test('第二次调用命中缓存：返回同一个 Buffer，不重新编译', async () => {
		const documentPath = await writeDocument();

		const first = await compileTypstDocument({ contentDir, documentPath });
		const second = await compileTypstDocument({ contentDir, documentPath });

		expect(first.ok && second.ok).toBe(true);
		if (!first.ok || !second.ok) return;
		expect(second.pdf).toBe(first.pdf);
		expect(second.hash).toBe(first.hash);
	});

	test('被 include 的片段改了，缓存失效并重新编译', async () => {
		const documentPath = await writeDocument();

		const first = await compileTypstDocument({ contentDir, documentPath });
		const partialPath = join(contentDir, 'partial.typ');
		await writeFixture('partial.typ', 'Partial content changed\n');
		await ageFile(partialPath, 60); // 明确改掉 mtime，绕开毫秒精度

		const second = await compileTypstDocument({ contentDir, documentPath });

		expect(first.ok && second.ok).toBe(true);
		if (!first.ok || !second.ok) return;
		expect(second.hash).not.toBe(first.hash);
		expect(second.pdf).not.toBe(first.pdf);
	});

	test('文档自身改了，缓存同样失效', async () => {
		const documentPath = await writeDocument();

		const first = await compileTypstDocument({ contentDir, documentPath });
		await writeFixture(documentPath, `${DOCUMENT_SOURCE}\n\nAppended line\n`);
		await ageFile(join(contentDir, documentPath), 60);

		const second = await compileTypstDocument({ contentDir, documentPath });

		expect(first.ok && second.ok).toBe(true);
		if (!first.ok || !second.ok) return;
		expect(second.hash).not.toBe(first.hash);
	});

	test('依赖文件不见了也能收场：报编译失败，不抛异常', async () => {
		await writeDocument();
		await rm(join(contentDir, 'partial.typ'));

		const result = await compileTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(false);
	});
});
