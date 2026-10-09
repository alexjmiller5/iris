import type { EditorMessage } from './editor-island';
import { isInlineImage, type RetainedFileResolver } from './retained-files';

/** Bytes arrive from the host. The editor island never gets a URL credential or network transport. */
export function editorFiles(send: (message: EditorMessage) => void) {
	let sequence = 0;
	const pending = new Map<
		string,
		{ id: string; resolve(value: Record<string, unknown>): void; reject(error: Error): void }
	>();
	function request(
		type: 'file' | 'openFile' | 'openLink' | 'core',
		id: string,
		value: string,
		signal?: AbortSignal
	): Promise<Record<string, unknown>> {
		signal?.throwIfAborted();
		const request = `${id}:${++sequence}`;
		return new Promise((resolve, reject) => {
			const abort = () => {
				pending.delete(request);
				reject(Error('File request canceled.'));
			};
			signal?.addEventListener('abort', abort, { once: true });
			pending.set(request, {
				id,
				resolve(reply) {
					signal?.removeEventListener('abort', abort);
					resolve(reply);
				},
				reject(error) {
					signal?.removeEventListener('abort', abort);
					reject(error);
				}
			});
			send({ type, id, request, value });
		});
	}
	return {
		resolve(id: string): RetainedFileResolver {
			return async (key, signal) => {
				const reply = await request('file', id, key, signal);
				const maximumBytes = 8 * 1024 * 1024;
				if (
					typeof reply.base64 !== 'string' ||
					typeof reply.contentType !== 'string' ||
					!isInlineImage(reply.contentType) ||
					reply.base64.length > Math.ceil(maximumBytes / 3) * 4
				)
					throw Error('Invalid retained file response.');
				const data = Uint8Array.from(atob(reply.base64), (c) => c.charCodeAt(0));
				if (data.byteLength > maximumBytes) throw Error('Image exceeds the 8 MB preview limit.');
				const url = URL.createObjectURL(new Blob([data], { type: reply.contentType }));
				return { url, contentType: reply.contentType, dispose: () => URL.revokeObjectURL(url) };
			};
		},
		async openFile(id: string, key: string) {
			await request('openFile', id, key);
		},
		/** Read-only core operations for mentions and embeds; the host enforces the allowlist. */
		async core(id: string, op: string, args: unknown) {
			return (await request('core', id, JSON.stringify({ op, args }))).result;
		},
		async openLink(id: string, href: string) {
			return (await request('openLink', id, href)).opened === true;
		},
		receive(input: unknown) {
			if (!input || typeof input !== 'object') return;
			const reply = input as Record<string, unknown>;
			if (typeof reply.request !== 'string') return;
			const waiting = pending.get(reply.request);
			if (!waiting || waiting.id !== reply.id) return;
			pending.delete(reply.request);
			if (typeof reply.error === 'string') waiting.reject(Error(reply.error));
			else waiting.resolve(reply);
		},
		dispose() {
			for (const item of pending.values()) item.reject(Error('Editor closed.'));
			pending.clear();
		}
	};
}
