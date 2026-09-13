import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from 'vitest';
import { renderTypstDocument } from './typst-compile';

/**
 * 这些用例真调本机的 typst。没装 typst 的机器上整组跳过，而不是整片挂掉。
 *
 * 这里锁的是**结构输出**：正文片段、语义标签、按目标分流的摆放，以及诊断的清洗。
 * 「粉笔风格长什么样」不在这里 —— 那是站点样式表的事，由手点验证。
 */
const hasTypst = spawnSync('typst', ['--version']).status === 0;

const DOCUMENT_SOURCE = [
	'= Preview Test',
	'',
	'Body text',
	'',
	'#include "partial.typ"'
].join('\n');

let contentDir: string;

beforeEach(async () => {
	contentDir = await mkdtemp(join(tmpdir(), 'typst-render-'));
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

describe.skipIf(!hasTypst)('renderTypstDocument', () => {
	test('渲染成功返回正文片段，不带 html / head / body 外壳', async () => {
		await writeFixture('partial.typ', 'Partial content\n');
		await writeFixture('cv.typ', DOCUMENT_SOURCE);

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.html).toContain('<h2>Preview Test</h2>');
		expect(result.html).toContain('Partial content');
		// 外壳归本站管，文档不许带出来
		expect(result.html).not.toContain('<html');
		expect(result.html).not.toContain('<body');
		expect(result.html).not.toContain('<head');
	});

	test('标题、列表、表格、strong 都保留成语义标签', async () => {
		await writeFixture(
			'cv.typ',
			['= H', '', '- *bold* item', '', '#table(columns: 2, [a], [b])'].join('\n')
		);

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.html).toContain('<h2>H</h2>');
		expect(result.html).toContain('<ul>');
		expect(result.html).toContain('<strong>bold</strong>');
		expect(result.html).toContain('<table>');
	});

	test('按导出目标分流：html 目标下拿到 div.cv-columns，而不是 code', async () => {
		await writeFixture(
			'cv.typ',
			[
				'#let site-columns(..body) = context {',
				'  if target() == "html" {',
				'    html.elem("div", body.pos().join(), attrs: (class: "cv-columns"))',
				'  } else {',
				'    grid(columns: (1fr, 2fr), ..body.pos())',
				'  }',
				'}',
				'#site-columns([LEFT], [RIGHT])'
			].join('\n')
		);

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.html).toContain('<div class="cv-columns">');
		expect(result.html).toContain('LEFT');
		expect(result.html).toContain('RIGHT');
		// 曾经的坑：把内容数组直接交给 html.elem，整个数组会被渲染成 <code>
		expect(result.html).not.toContain('<code');
	});

	test('分隔线：官方 divider 在 HTML 目标下就是 <hr>，两种格式共用一条样式', async () => {
		await writeFixture('cv.typ', '= Before\n\n#divider()\n\n= After\n');

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.html).toContain('<hr>');
	});

	test('每次都会出现的实验特性总提示不进诊断，用户不该看见它', async () => {
		await writeFixture('cv.typ', '= Hi\n');

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.diagnostics.join('\n')).not.toContain('under active development');
	});

	test('语法错误返回带源位置的诊断，且诊断里有文件名', async () => {
		await writeFixture('broken.typ', '= Hi\n#let x = \n');

		const result = await renderTypstDocument({ contentDir, documentPath: 'broken.typ' });

		expect(result.ok).toBe(false);
		if (result.ok) return;
		expect(result.diagnostics.join('\n')).toContain('broken.typ:2');
	});

	test('依赖文件不见了也收场：报渲染失败，不抛异常', async () => {
		await writeFixture('partial.typ', 'Partial\n');
		await writeFixture('cv.typ', DOCUMENT_SOURCE);
		await rm(join(contentDir, 'partial.typ'));

		const result = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(result.ok).toBe(false);
	});

	test('改了源文件下次渲染就是新内容 —— 没有缓存要失效', async () => {
		await writeFixture('cv.typ', '= First\n');

		const first = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });
		await writeFixture('cv.typ', '= Second\n');
		const second = await renderTypstDocument({ contentDir, documentPath: 'cv.typ' });

		expect(first.ok && second.ok).toBe(true);
		if (!first.ok || !second.ok) return;
		expect(first.html).toContain('First');
		expect(second.html).toContain('Second');
	});
});
