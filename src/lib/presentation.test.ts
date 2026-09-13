import { describe, expect, test } from 'vitest';
import { nearestSlideIndex, slideOverflows, stepSlide } from './presentation';

describe('nearestSlideIndex', () => {
	test('正好停在某一张上', () => {
		expect(nearestSlideIndex([0, 400, 800, 1200], 800)).toBe(2);
	});

	test('停在两张中间时取更近的那张', () => {
		expect(nearestSlideIndex([0, 400, 800], 310)).toBe(1);
		expect(nearestSlideIndex([0, 400, 800], 290)).toBe(1);
		expect(nearestSlideIndex([0, 400, 800], 190)).toBe(0);
	});

	test('第一张之前和最后一张之后都夹在两端', () => {
		expect(nearestSlideIndex([0, 400, 800], -50)).toBe(0);
		expect(nearestSlideIndex([0, 400, 800], 9999)).toBe(2);
	});

	test('只有一张时永远是它', () => {
		expect(nearestSlideIndex([0], 12345)).toBe(0);
	});

	test('没有幻灯片时返回 -1，调用方据此不显示计数器', () => {
		expect(nearestSlideIndex([], 0)).toBe(-1);
	});

	/**
	 * 这个用例是「取最近」而不是「取最后一个已滚过的」的原因：容器尺寸变化会让
	 * 偏移量整体失效，此时前者最多错一张，后者会一路错到底。
	 */
	test('偏移量整体缩小时不会跳到第一张', () => {
		expect(nearestSlideIndex([0, 100, 200, 300], 290)).toBe(3);
	});
});

describe('stepSlide', () => {
	test('正常前进后退', () => {
		expect(stepSlide(1, 1, 5)).toBe(2);
		expect(stepSlide(1, -1, 5)).toBe(0);
	});

	test('到头就停住，不循环', () => {
		expect(stepSlide(4, 1, 5)).toBe(4);
		expect(stepSlide(0, -1, 5)).toBe(0);
	});

	test('大步长也只夹到端点', () => {
		expect(stepSlide(0, 99, 5)).toBe(4);
		expect(stepSlide(4, -99, 5)).toBe(0);
	});

	test('没有幻灯片时返回 -1', () => {
		expect(stepSlide(0, 1, 0)).toBe(-1);
	});
});

describe('slideOverflows', () => {
	test('内容高于视口算溢出', () => {
		expect(slideOverflows(1200, 800)).toBe(true);
	});

	test('内容放得下就不算', () => {
		expect(slideOverflows(600, 800)).toBe(false);
	});

	/** 1px 容差：亚像素布局会让刚好等高的内容报出 0.3px 的差，不该因此允许滚动。 */
	test('刚好等高时不算溢出', () => {
		expect(slideOverflows(800, 800)).toBe(false);
		expect(slideOverflows(800.5, 800)).toBe(false);
		expect(slideOverflows(802, 800)).toBe(true);
	});
});
