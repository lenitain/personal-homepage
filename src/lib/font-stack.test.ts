import { describe, expect, test } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 字体栈只能有一处定义。
 *
 * 之前 `'Kalam', 'Patrick Hand', ...` 这条链被抄在四个地方，换一次字体要改四遍 ——
 * 漏掉任何一处，那一块就会悄悄留在旧字体上，而且不会有任何报错。现在真源是
 * `+layout.svelte` 里 `:global(body)` 上的 `--font-chalk`，别处一律 `var(--font-chalk)`。
 *
 * 这条约束不做成测试就会在下次改样式时退化，所以在这里盯着。
 */

const SRC_DIR = fileURLToPath(new URL('..', import.meta.url));

/** 允许写死字体族的那一个文件（相对 src/）。 */
const SINGLE_SOURCE = 'routes/+layout.svelte';

/** 一条 font-family 声明，值里带引号 = 直接写了字体族名字（而不是 var(...)）。 */
const HARDCODED_FAMILY = /font-family:\s*[^;]*['"]/;

function svelteFiles(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) return svelteFiles(path);
		return entry.name.endsWith('.svelte') ? [path] : [];
	});
}

/** 写死了字体族的样式文件，相对 src/ 排序返回。 */
function filesHardcodingFontFamily(): string[] {
	return svelteFiles(SRC_DIR)
		.filter((path) => HARDCODED_FAMILY.test(readFileSync(path, 'utf-8')))
		.map((path) => relative(SRC_DIR, path))
		.sort();
}

describe('字体栈的唯一真源', () => {
	test('除 +layout.svelte 外，没有别处写死字体族', () => {
		expect(filesHardcodingFontFamily()).toEqual([SINGLE_SOURCE]);
	});

	test('真源里定义了 --font-chalk，并且中文三个字体按 A→B→C 排', () => {
		const layout = readFileSync(join(SRC_DIR, SINGLE_SOURCE), 'utf-8');
		const declaration = layout.match(/--font-chalk:\s*([^;]+);/)?.[1] ?? '';

		expect(declaration).toContain("'ZCOOL KuaiLe'");
		expect(declaration).toContain("'LXGW WenKai'");
		expect(declaration).toContain("'Ma Shan Zheng'");
		expect(declaration.indexOf("'ZCOOL KuaiLe'")).toBeLessThan(declaration.indexOf("'LXGW WenKai'"));
		expect(declaration.indexOf("'LXGW WenKai'")).toBeLessThan(declaration.indexOf("'Ma Shan Zheng'"));
	});

	test('日文的 Yusei Magic 已经出局 —— 站内没有假名，它只贡献日文字形和 1.1 MB', () => {
		expect(readFileSync(join(SRC_DIR, SINGLE_SOURCE), 'utf-8')).not.toContain('Yusei');
	});
});
