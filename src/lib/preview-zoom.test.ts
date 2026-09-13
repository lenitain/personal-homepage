import { beforeEach, describe, expect, test } from 'vitest';
import {
	readDocumentScaleValue,
	readMarkdownFontScale,
	rememberDocumentScaleValue,
	resetMarkdownFontScale,
	stepMarkdownFontScale
} from './preview-zoom';

/**
 * 这些状态活在模块作用域里 —— 换文件会重挂载组件，存组件里就丢了。
 * 每个用例先把两边都复位，免得相互串味。
 */
beforeEach(() => {
	resetMarkdownFontScale();
	rememberDocumentScaleValue('page-width');
});

describe('preview-zoom', () => {
	test('markdown 字号默认是 1，文档缩放默认是适应宽度', () => {
		expect(readMarkdownFontScale()).toBe(1);
		expect(readDocumentScaleValue()).toBe('page-width');
	});

	test('放大缩小按倍率走', () => {
		expect(stepMarkdownFontScale('in')).toBeCloseTo(1.1);
		expect(stepMarkdownFontScale('in')).toBeCloseTo(1.21);
		expect(stepMarkdownFontScale('out')).toBeCloseTo(1.1);
	});

	test('字号上下都有夹子，怎么点都不会跑飞', () => {
		for (let i = 0; i < 30; i++) stepMarkdownFontScale('in');
		expect(readMarkdownFontScale()).toBe(2);

		for (let i = 0; i < 60; i++) stepMarkdownFontScale('out');
		expect(readMarkdownFontScale()).toBe(0.75);
	});

	test('复位回到默认字号', () => {
		stepMarkdownFontScale('in');
		stepMarkdownFontScale('in');

		expect(resetMarkdownFontScale()).toBe(1);
		expect(readMarkdownFontScale()).toBe(1);
	});

	test('文档缩放记住数字（pdf 的 currentScale），也记得住适应宽度这个模式', () => {
		expect(readDocumentScaleValue()).toBe('page-width');

		rememberDocumentScaleValue(1.884);
		expect(readDocumentScaleValue()).toBe(1.884);

		rememberDocumentScaleValue('page-width');
		expect(readDocumentScaleValue()).toBe('page-width');
	});
});
