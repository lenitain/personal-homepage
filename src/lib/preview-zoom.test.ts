import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

const FONT_KEY = 'preview-zoom:markdown-font-scale';
const DOC_KEY = 'preview-zoom:document-scale';

/** 够用的 localStorage 替身。 */
function memoryStorage() {
	const entries = new Map<string, string>();
	return {
		getItem: (key: string) => entries.get(key) ?? null,
		setItem: (key: string, value: string) => void entries.set(key, value),
		removeItem: (key: string) => void entries.delete(key)
	};
}

/** 重新加载模块 —— 相当于刷新页面：模块级变量清空，只剩 localStorage 里的东西。 */
async function reloadModule() {
	vi.resetModules();
	return await import('./preview-zoom');
}

beforeEach(() => {
	vi.stubGlobal('localStorage', memoryStorage());
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('preview-zoom', () => {
	test('默认是字号 1、文档适应宽度', async () => {
		const zoom = await reloadModule();

		expect(zoom.readMarkdownFontScale()).toBe(1);
		expect(zoom.readDocumentScaleValue()).toBe('page-width');
	});

	test('放大缩小按倍率走', async () => {
		const zoom = await reloadModule();

		expect(zoom.stepMarkdownFontScale('in')).toBeCloseTo(1.1);
		expect(zoom.stepMarkdownFontScale('in')).toBeCloseTo(1.21);
		expect(zoom.stepMarkdownFontScale('out')).toBeCloseTo(1.1);
	});

	test('字号上下都有夹子，怎么点都不会跑飞', async () => {
		const zoom = await reloadModule();

		for (let i = 0; i < 30; i++) zoom.stepMarkdownFontScale('in');
		expect(zoom.readMarkdownFontScale()).toBe(2);

		for (let i = 0; i < 60; i++) zoom.stepMarkdownFontScale('out');
		expect(zoom.readMarkdownFontScale()).toBe(0.75);
	});

	test('复位回到默认字号', async () => {
		const zoom = await reloadModule();
		zoom.stepMarkdownFontScale('in');
		zoom.stepMarkdownFontScale('in');

		expect(zoom.resetMarkdownFontScale()).toBe(1);
	});

	test('刷新页面后字号还在', async () => {
		const before = await reloadModule();
		before.stepMarkdownFontScale('in');
		before.stepMarkdownFontScale('in');

		const after = await reloadModule();

		expect(after.readMarkdownFontScale()).toBeCloseTo(1.21);
	});

	test('刷新页面后文档缩放还在，连「适应宽度」这个模式也记得住', async () => {
		const before = await reloadModule();
		before.rememberDocumentScaleValue(1.884);

		const after = await reloadModule();
		expect(after.readDocumentScaleValue()).toBe(1.884);

		after.rememberDocumentScaleValue('page-width');
		expect((await reloadModule()).readDocumentScaleValue()).toBe('page-width');
	});

	test('存坏的数字退回默认 —— 不能让 pdf.js 收到 NaN 或非法倍率', async () => {
		localStorage.setItem(DOC_KEY, 'NaN');
		expect((await reloadModule()).readDocumentScaleValue()).toBe('page-width');

		localStorage.setItem(DOC_KEY, 'abc');
		expect((await reloadModule()).readDocumentScaleValue()).toBe('page-width');

		localStorage.setItem(DOC_KEY, '-3');
		expect((await reloadModule()).readDocumentScaleValue()).toBe('page-width');
	});

	test('存坏的字号夹回合法区间', async () => {
		localStorage.setItem(FONT_KEY, '99');
		expect((await reloadModule()).readMarkdownFontScale()).toBe(2);

		localStorage.setItem(FONT_KEY, '0.01');
		expect((await reloadModule()).readMarkdownFontScale()).toBe(0.75);
	});

	test('localStorage 不可用（隐私模式）时照常工作，只是不持久化', async () => {
		vi.stubGlobal('localStorage', {
			getItem() {
				throw new Error('storage denied');
			},
			setItem() {
				throw new Error('storage denied');
			}
		});

		const zoom = await reloadModule();

		expect(zoom.stepMarkdownFontScale('in')).toBeCloseTo(1.1);
		expect(zoom.readMarkdownFontScale()).toBeCloseTo(1.1);
		expect(zoom.readDocumentScaleValue()).toBe('page-width');
	});
});
