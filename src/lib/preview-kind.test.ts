import { describe, expect, test } from 'vitest';
import { previewKindOf } from './preview-kind';

describe('previewKindOf', () => {
	test('三种可预览的扩展名各自映射到一种类型', () => {
		expect(previewKindOf('readme.md')).toBe('markdown');
		expect(previewKindOf('cv.typ')).toBe('typst');
		expect(previewKindOf('cv.pdf')).toBe('pdf');
	});

	test('扩展名比较不看大小写', () => {
		expect(previewKindOf('README.MD')).toBe('markdown');
		expect(previewKindOf('CV.Typ')).toBe('typst');
		expect(previewKindOf('CV.PDF')).toBe('pdf');
	});

	test('多点文件名取最后一个点', () => {
		expect(previewKindOf('cv.v2.typ')).toBe('typst');
		expect(previewKindOf('2026.09.report.md')).toBe('markdown');
	});

	test('没有扩展名就没有类型', () => {
		expect(previewKindOf('readme')).toBeNull();
		expect(previewKindOf('Makefile')).toBeNull();
	});

	test('像但不相等的扩展名不算', () => {
		expect(previewKindOf('notes.mdx')).toBeNull();
		expect(previewKindOf('notes.markdown')).toBeNull();
		expect(previewKindOf('paper.typst')).toBeNull();
		expect(previewKindOf('scan.pdf.txt')).toBeNull();
	});

	test('点后面什么都没有不算', () => {
		expect(previewKindOf('notes.')).toBeNull();
	});
});
