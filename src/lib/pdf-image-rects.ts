export interface PageRect {
	x: number;
	y: number;
	width: number;
	height: number;
}

/** 豁免所需的最小算子编号集合，由调用方从 pdf.js 的 `OPS` 里取，纯模块不依赖 pdf.js。 */
export interface ImageOpCodes {
	save: number;
	restore: number;
	transform: number;
	paintImageXObject: number;
	paintInlineImageXObject: number;
}

export interface ImageRectRequest {
	fnArray: readonly number[];
	argsArray: readonly unknown[];
	/** `page.getViewport({ scale })` 的 transform。 */
	viewportTransform: readonly number[];
	ops: ImageOpCodes;
}

/** 一张纸上最多豁免这么多张图；再多就放弃治疗，避免合成的开销失控。 */
const MAX_IMAGE_RECTS = 64;

/**
 * 找出页面上所有图像占的矩形（视口坐标，即 CSS 像素），用来在反色时把照片豁免掉。
 *
 * PDF 的图像画在**当前变换矩阵下的单位方框**里（`paintImageXObject` 的参数是
 * `[objId, width, height]`，宽高只是图像自身像素尺寸，不影响落点），所以跟踪
 * `save` / `restore` / `transform` 就能算出每张图的位置。旋转与斜切按包围盒处理。
 *
 * 有意排除的两类：
 * - `paintImageMaskXObject`（图像模板）：它只是个蒙版，颜色来自当时的填充色。
 *   豁免它会把字形原色留在暗底上 —— 深色字直接看不见
 * - `paintImageXObjectRepeat`（平铺）：参数形状与单张不同，且常是小图案重复，
 *   豁免价值低。不豁免的代价只是这些小图跟着被反色
 *
 * 整页扫描件会因此被完整保留（整页就是一张图），不会变暗 —— 这是「图像豁免」的必然结果。
 */
export function imageRectsFromOperatorList(request: ImageRectRequest): PageRect[] {
	const { fnArray, argsArray, viewportTransform, ops } = request;
	const rects: PageRect[] = [];
	const saved: number[][] = [];
	let ctm = [1, 0, 0, 1, 0, 0];

	for (let index = 0; index < fnArray.length; index++) {
		const operator = fnArray[index];

		if (operator === ops.save) {
			saved.push([...ctm]);
			continue;
		}

		if (operator === ops.restore) {
			ctm = saved.pop() ?? [1, 0, 0, 1, 0, 0];
			continue;
		}

		if (operator === ops.transform) {
			const args = argsArray[index];
			if (isTransformArgs(args)) ctm = multiplyTransform(ctm, args);
			continue;
		}

		if (operator !== ops.paintImageXObject && operator !== ops.paintInlineImageXObject) {
			continue;
		}

		if (rects.length >= MAX_IMAGE_RECTS) continue;

		const rect = unitSquareBounds(multiplyTransform([...viewportTransform], ctm));
		if (rect) rects.push(rect);
	}

	return rects;
}

function isTransformArgs(args: unknown): args is number[] {
	return (
		Array.isArray(args) && args.length >= 6 && args.slice(0, 6).every((n) => typeof n === 'number')
	);
}

/** 六元矩阵相乘，约定与 pdf.js 的 `Util.transform(m1, m2)` 一致：先 m2 后 m1。 */
function multiplyTransform(m1: number[], m2: number[]): number[] {
	return [
		m1[0] * m2[0] + m1[2] * m2[1],
		m1[1] * m2[0] + m1[3] * m2[1],
		m1[0] * m2[2] + m1[2] * m2[3],
		m1[1] * m2[2] + m1[3] * m2[3],
		m1[0] * m2[4] + m1[2] * m2[5] + m1[4],
		m1[1] * m2[4] + m1[3] * m2[5] + m1[5]
	];
}

/** 单位方框四个角过一遍变换，取包围盒；零面积返回 null。 */
function unitSquareBounds(m: number[]): PageRect | null {
	const corners = [
		[m[4], m[5]],
		[m[0] + m[4], m[1] + m[5]],
		[m[2] + m[4], m[3] + m[5]],
		[m[0] + m[2] + m[4], m[1] + m[3] + m[5]]
	];

	const xs = corners.map(([x]) => x);
	const ys = corners.map(([, y]) => y);
	const x = Math.min(...xs);
	const y = Math.min(...ys);
	const width = Math.max(...xs) - x;
	const height = Math.max(...ys) - y;

	if (!(width > 0) || !(height > 0)) return null;

	return { x, y, width, height };
}
