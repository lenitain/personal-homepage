import { describe, expect, test } from 'vitest';
// 用真实的 OPS 常量跑测试，这样「算子编号有没有对上」也被锁住了。
// 纯模块本身不依赖 pdf.js，编号由调用方传进来。
import { OPS } from 'pdfjs-dist/legacy/build/pdf.mjs';
import { imageRectsFromOperatorList } from './pdf-image-rects';

/** 只包含豁免所需的算子编号，跟组件里从 pdf.js 取到的是同一组。 */
const imageOps = {
	save: OPS.save,
	restore: OPS.restore,
	transform: OPS.transform,
	paintImageXObject: OPS.paintImageXObject,
	paintInlineImageXObject: OPS.paintInlineImageXObject
};

/** 单位方框在给定变换下占的矩形；viewport 用恒等变换，算出来的就是 PDF 用户空间坐标。 */
function rects(fnArray: number[], argsArray: unknown[], viewportTransform = [1, 0, 0, 1, 0, 0]) {
	return imageRectsFromOperatorList({ fnArray, argsArray, viewportTransform, ops: imageOps });
}

describe('imageRectsFromOperatorList', () => {
	test('把单位方框按当前变换映射成矩形', () => {
		// 平移 (10, 20) 后放大 100x50：矩形就是 (10,20) 100x50
		const result = rects(
			[OPS.save, OPS.transform, OPS.paintImageXObject, OPS.restore],
			[null, [100, 0, 0, 50, 10, 20], ['img_1', 100, 50], null]
		);

		expect(result).toEqual([{ x: 10, y: 20, width: 100, height: 50 }]);
	});

	test('连续两个变换会叠加', () => {
		const result = rects(
			[OPS.transform, OPS.transform, OPS.paintImageXObject],
			[
				[1, 0, 0, 1, 5, 5],
				[2, 0, 0, 2, 0, 0],
				['img_1', 10, 10]
			]
		);

		expect(result).toEqual([{ x: 5, y: 5, width: 2, height: 2 }]);
	});

	test('restore 之后回到 save 时的变换，不会串到下一张图', () => {
		const result = rects(
			[
				OPS.save,
				OPS.transform,
				OPS.paintImageXObject,
				OPS.restore,
				OPS.paintImageXObject
			],
			[
				null,
				[100, 0, 0, 100, 10, 10],
				['img_1', 10, 10],
				null,
				['img_2', 10, 10]
			]
		);

		expect(result).toEqual([
			{ x: 10, y: 10, width: 100, height: 100 },
			{ x: 0, y: 0, width: 1, height: 1 }
		]);
	});

	test('viewport 变换会作用在结果上（PDF 的 y 轴朝上）', () => {
		// 页高 800、y 轴翻转，再放大 2 倍：单位方框落到 y = 1600 - 2 = 1598
		const result = rects(
			[OPS.transform, OPS.paintImageXObject],
			[
				[1, 0, 0, 1, 0, 0],
				['img_1', 1, 1]
			],
			[2, 0, 0, -2, 0, 1600]
		);

		expect(result).toEqual([{ x: 0, y: 1598, width: 2, height: 2 }]);
	});

	test('旋转过的图像取包围盒', () => {
		// 旋转 90 度并纵向放大 2 倍：单位方框变成 1 宽 2 高的矩形，落在 y 轴负侧
		const result = rects(
			[OPS.transform, OPS.paintImageXObject],
			[
				[0, 2, -1, 0, 0, 0],
				['img_1', 1, 2]
			]
		);

		expect(result).toEqual([{ x: -1, y: 0, width: 1, height: 2 }]);
	});

	test('内联图像同样豁免', () => {
		const result = rects(
			[OPS.transform, OPS.paintInlineImageXObject],
			[
				[10, 0, 0, 10, 0, 0],
				[{ width: 4, height: 4 }]
			]
		);

		expect(result).toEqual([{ x: 0, y: 0, width: 10, height: 10 }]);
	});

	test('图像模板不算图像 —— 它的颜色来自填充色，豁免了会把字形留在暗底上', () => {
		const result = rects([OPS.paintImageMaskXObject], [{ width: 4, height: 4 }]);

		expect(result).toEqual([]);
	});

	test('零面积的图像被丢掉', () => {
		const result = rects(
			[OPS.transform, OPS.paintImageXObject],
			[
				[0, 0, 0, 0, 5, 5],
				['img_1', 1, 1]
			]
		);

		expect(result).toEqual([]);
	});

	test('算子列表为空时返回空数组', () => {
		expect(rects([], [])).toEqual([]);
	});

	test('restore 比 save 多也不会炸', () => {
		const result = rects([OPS.restore, OPS.transform, OPS.paintImageXObject], [
			null,
			[1, 0, 0, 1, 3, 3],
			['img_1', 1, 1]
		]);

		expect(result).toEqual([{ x: 3, y: 3, width: 1, height: 1 }]);
	});
});
