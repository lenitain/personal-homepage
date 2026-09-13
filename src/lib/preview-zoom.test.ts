import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

const FONT_KEY = 'preview-zoom:font-scale';

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
	test('默认字号是 1', async () => {
		const zoom = await reloadModule();

		expect(zoom.readFontScale()).toBe(1);
	});

	test('放大缩小按倍率走', async () => {
		const zoom = await reloadModule();

		expect(zoom.stepFontScale('in')).toBeCloseTo(1.1);
		expect(zoom.stepFontScale('in')).toBeCloseTo(1.21);
		expect(zoom.stepFontScale('out')).toBeCloseTo(1.1);
	});

	test('字号上下都有夹子，怎么点都不会跑飞', async () => {
		const zoom = await reloadModule();

		for (let i = 0; i < 30; i++) zoom.stepFontScale('in');
		expect(zoom.readFontScale()).toBe(2);

		for (let i = 0; i < 60; i++) zoom.stepFontScale('out');
		expect(zoom.readFontScale()).toBe(0.75);
	});

	test('复位回到默认字号', async () => {
		const zoom = await reloadModule();
		zoom.stepFontScale('in');
		zoom.stepFontScale('in');

		expect(zoom.resetFontScale()).toBe(1);
	});

	test('刷新页面后字号还在', async () => {
		const before = await reloadModule();
		before.stepFontScale('in');
		before.stepFontScale('in');

		const after = await reloadModule();

		expect(after.readFontScale()).toBeCloseTo(1.21);
	});

	test('存坏的字号夹回合法区间 —— 不能让正文算出 NaN 字号', async () => {
		localStorage.setItem(FONT_KEY, '99');
		expect((await reloadModule()).readFontScale()).toBe(2);

		localStorage.setItem(FONT_KEY, '0.01');
		expect((await reloadModule()).readFontScale()).toBe(0.75);

		localStorage.setItem(FONT_KEY, 'NaN');
		expect((await reloadModule()).readFontScale()).toBe(1);

		localStorage.setItem(FONT_KEY, 'abc');
		expect((await reloadModule()).readFontScale()).toBe(1);
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

		expect(zoom.stepFontScale('in')).toBeCloseTo(1.1);
		expect(zoom.readFontScale()).toBeCloseTo(1.1);
	});
});
