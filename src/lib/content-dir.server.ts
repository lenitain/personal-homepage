import { join } from 'node:path';

/**
 * content/ 的绝对路径 —— 全站内容目录的唯一真相。
 *
 * 服务端专用：`.server.ts` 后缀让 SvelteKit 在客户端误引时报错。
 */
export const CONTENT_DIR = join(process.cwd(), 'content');
