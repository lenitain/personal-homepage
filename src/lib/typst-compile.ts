import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { CHALK_PALETTE } from './chalk-palette';

/** 编译超时。文档若用 @preview 包，首次编译要联网下载，10 秒是够的；超了按失败上报。 */
const COMPILE_TIMEOUT_MS = 10_000;

/** 编译缓存的总字节上限，超了按插入顺序淘汰最旧的。 */
const CACHE_LIMIT_BYTES = 64 * 1024 * 1024;

/**
 * 注入主题的 wrapper 文件名前缀。
 *
 * 点号开头 ⇒ 文件树会跳过它；记录依赖时也要按这个前缀把它自己滤掉，否则它会因为
 * 「编译完就被删了」让缓存永远无法命中。
 */
const PREVIEW_WRAPPER_PREFIX = '.preview-';

/** 站点主题色，来自共用的调色板模块（改色要同时改 `+layout.svelte` 的 CSS 变量）。 */
const TYPST_THEME_PREAMBLE = `#set page(fill: rgb("${CHALK_PALETTE.board}"))
#set text(fill: rgb("${CHALK_PALETTE.ink}"))
#show link: set text(fill: rgb("${CHALK_PALETTE.link}"))
#show raw:  set text(fill: rgb("${CHALK_PALETTE.code}"))`;

export type TypstCompileResult =
	| { ok: true; pdf: Buffer; hash: string }
	| { ok: false; diagnostics: string[] };

export interface TypstCompileRequest {
	/** content/ 的绝对路径。 */
	contentDir: string;
	/** 相对 content/ 的 .typ 路径，例如 `cv.typ` 或 `about/cv.typ`。 */
	documentPath: string;
}

interface CompileCacheEntry {
	hash: string;
	/** 上次编译真实读过的文件，相对 content/。wrapper 已滤掉。 */
	inputs: string[];
	pdf: Buffer;
}

const compileCache = new Map<string, CompileCacheEntry>();
let cacheBytes = 0;

/**
 * 编译 typst 文档 —— 把一篇 .typ 编译成带站点粉笔主题的 pdf。
 *
 * 主题靠一个临时 wrapper 注入（`#set page(fill:)` / `#set text(fill:)` 等），
 * wrapper 必须与文档同目录，这样文档里的相对 `#include`、`#image` 才按原样解析；
 * 编译完在 finally 里删掉。产物缓存在内存里，缓存键是 typst `--deps` 报出来的
 * 真实依赖文件的 mtime + size，所以改文档或改它 include 的片段都会失效。
 *
 * 失败不抛异常，返回原始诊断（一行式、已把 wrapper 文件名换回文档名），交给路由变成 422。
 */
export async function compileTypstDocument(
	request: TypstCompileRequest
): Promise<TypstCompileResult> {
	const { contentDir, documentPath } = request;
	const absolutePath = join(contentDir, documentPath);

	const cached = compileCache.get(absolutePath);
	if (cached && (await inputsStillMatch(contentDir, documentPath, cached.inputs, cached.hash))) {
		return { ok: true, pdf: cached.pdf, hash: cached.hash };
	}

	const workDir = await mkdtemp(join(tmpdir(), 'typst-preview-'));
	const wrapperName = `${PREVIEW_WRAPPER_PREFIX}${randomUUID()}.typ`;
	const wrapperPath = join(dirname(absolutePath), wrapperName);
	const wrapperRelativePath = join(dirname(documentPath), wrapperName);

	try {
		await writeFile(
			wrapperPath,
			`${TYPST_THEME_PREAMBLE}\n#include "${basename(documentPath)}"\n`,
			'utf-8'
		);

		const depsPath = join(workDir, 'deps.json');
		const outputPath = join(workDir, 'out.pdf');
		await runTypst(
			[
				'compile',
				'--format',
				'pdf',
				'--root',
				'.',
				'--deps',
				depsPath,
				'--diagnostic-format',
				'short',
				wrapperRelativePath,
				outputPath
			],
			contentDir
		);

		const pdf = await readFile(outputPath);
		const inputs = await readDependencyInputs(depsPath);
		const hash = await hashInputFiles(contentDir, documentPath, inputs);
		rememberCompilation(absolutePath, { hash, inputs, pdf });

		return { ok: true, pdf, hash };
	} catch (error) {
		return { ok: false, diagnostics: describeCompileFailure(error, wrapperName, documentPath) };
	} finally {
		await rm(wrapperPath, { force: true });
		await rm(workDir, { recursive: true, force: true });
	}
}

/** 跑一次 typst，失败时把 stdout / stderr 一并挂到错误对象上，供诊断清洗使用。 */
function runTypst(args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
	return new Promise((resolvePromise, rejectPromise) => {
		execFile(
			'typst',
			args,
			{ cwd, timeout: COMPILE_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
			(error, stdout, stderr) => {
				if (error) {
					rejectPromise(Object.assign(error, { stdout, stderr }));
					return;
				}
				resolvePromise({ stdout, stderr });
			}
		);
	});
}

/** 读 `--deps` 写出来的依赖清单，滤掉 wrapper 自己；读不到就返回空数组（等价于永不命中缓存）。 */
async function readDependencyInputs(depsPath: string): Promise<string[]> {
	const raw = await readFile(depsPath, 'utf-8').catch(() => '');
	try {
		const parsed = JSON.parse(raw) as { inputs?: unknown };
		if (!Array.isArray(parsed.inputs)) return [];
		return parsed.inputs.filter(
			(input): input is string =>
				typeof input === 'string' && !basename(input).startsWith(PREVIEW_WRAPPER_PREFIX)
		);
	} catch {
		return [];
	}
}

/** 依赖文件的哈希：排序后把每个文件的 `mtimeMs + size` 喂给 sha256。缺文件记为 missing。 */
async function hashInputFiles(
	contentDir: string,
	documentPath: string,
	inputs: readonly string[]
): Promise<string> {
	const digest = createHash('sha256');
	digest.update(documentPath);
	for (const input of [...inputs].sort()) {
		const stats = await stat(join(contentDir, input)).catch(() => null);
		digest.update(input);
		digest.update(stats ? `${stats.mtimeMs}:${stats.size}` : 'missing');
	}
	return digest.digest('hex').slice(0, 16);
}

async function inputsStillMatch(
	contentDir: string,
	documentPath: string,
	inputs: readonly string[],
	hash: string
): Promise<boolean> {
	if (inputs.length === 0) return false;
	return (await hashInputFiles(contentDir, documentPath, inputs)) === hash;
}

function rememberCompilation(absolutePath: string, entry: CompileCacheEntry): void {
	const previous = compileCache.get(absolutePath);
	if (previous) {
		cacheBytes -= previous.pdf.byteLength;
		compileCache.delete(absolutePath);
	}

	compileCache.set(absolutePath, entry);
	cacheBytes += entry.pdf.byteLength;

	while (cacheBytes > CACHE_LIMIT_BYTES && compileCache.size > 1) {
		const oldest = compileCache.keys().next();
		if (oldest.done) break;
		const evicted = compileCache.get(oldest.value);
		if (evicted) cacheBytes -= evicted.pdf.byteLength;
		compileCache.delete(oldest.value);
	}
}

/** 把 typst 的一行式诊断整理成字符串数组，并把 wrapper 的临时文件名换回文档路径。 */
function describeCompileFailure(
	error: unknown,
	wrapperName: string,
	documentPath: string
): string[] {
	const failure = error as { killed?: boolean; stderr?: string; stdout?: string; message?: string };

	if (failure?.killed) {
		return [`typst 编译超时（${COMPILE_TIMEOUT_MS / 1000} 秒），已中止`];
	}

	const raw = `${failure?.stderr ?? ''}${failure?.stdout ?? ''}`.trim();
	if (!raw) {
		return [`typst 编译失败：${failure?.message ?? '未知错误'}`];
	}

	return raw
		.split('\n')
		.map((line) => line.trimEnd())
		.filter((line) => line.length > 0)
		.map((line) => line.split(wrapperName).join(documentPath));
}
