import { describe, expect, test } from 'vitest';
import { join } from 'node:path';
import { resolveContentPath } from './content-path';

const contentDir = '/srv/content';

/** 只放 .pdf 的调用，跟 /raw 路由的用法一致。 */
function resolvePdf(urlPath: string): string | null {
	return resolveContentPath({ contentDir, urlPath, allowedExtensions: ['.pdf'] });
}

describe('resolveContentPath', () => {
	test('普通文件名解析成 content/ 下的绝对路径', () => {
		expect(resolvePdf('cv.pdf')).toBe(join(contentDir, 'cv.pdf'));
	});

	test('嵌套路径正常放行', () => {
		expect(resolvePdf('blog/notes.pdf')).toBe(join(contentDir, 'blog/notes.pdf'));
	});

	test('扩展名不在白名单就拒绝', () => {
		expect(resolvePdf('readme.md')).toBeNull();
		expect(resolvePdf('cv.typ')).toBeNull();
		expect(resolvePdf('diagram.png')).toBeNull();
	});

	test('扩展名比较不看大小写', () => {
		expect(resolvePdf('CV.PDF')).toBe(join(contentDir, 'CV.PDF'));
	});

	test('…段一律拒绝', () => {
		expect(resolvePdf('../secret.pdf')).toBeNull();
		expect(resolvePdf('a/../../secret.pdf')).toBeNull();
		expect(resolvePdf('a/../b.pdf')).toBeNull();
	});

	test('当前目录段也拒绝', () => {
		expect(resolvePdf('./cv.pdf')).toBeNull();
		expect(resolvePdf('a/./b.pdf')).toBeNull();
	});

	test('空段拒绝', () => {
		expect(resolvePdf('a//b.pdf')).toBeNull();
		expect(resolvePdf('blog/')).toBeNull();
		expect(resolvePdf('/cv.pdf')).toBeNull();
	});

	test('空串拒绝', () => {
		expect(resolvePdf('')).toBeNull();
	});

	test('NUL 字节拒绝', () => {
		expect(resolvePdf('cv\0.pdf')).toBeNull();
	});

	test('反斜杠拒绝 —— 在 Windows 上它是目录分隔符，会成为绕过口子', () => {
		expect(resolvePdf('..\\..\\secret.pdf')).toBeNull();
		expect(resolvePdf('a\\b.pdf')).toBeNull();
	});

	test('绝对路径拒绝，哪怕它真的以 content/ 开头', () => {
		expect(resolvePdf(`${contentDir}/cv.pdf`)).toBeNull();
	});

	test('编码后仍是字面量段的路径不构成穿越（由上层解码，这里只认结果）', () => {
		expect(resolvePdf('%2e%2e/secret.pdf')).toBe(join(contentDir, '%2e%2e/secret.pdf'));
	});
});
