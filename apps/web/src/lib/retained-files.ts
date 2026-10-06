import { createHttpHub } from 'life-ui-core/client';

export interface RetainedFile {
	url: string;
	contentType: string;
	dispose(): void;
}
export type RetainedFileResolver = (key: string, signal?: AbortSignal) => Promise<RetainedFile>;
const maximumBytes = 128 * 1024 * 1024;

function validKey(key: string): boolean {
	return (
		!!key &&
		key.length <= 2048 &&
		!/[\\\u0000-\u001f\u007f]/.test(key) &&
		key.split('/').every((part) => !!part && part !== '.' && part !== '..') &&
		!key.includes('://')
	);
}
/** Only canonical relative hub references carry implicit authorization. */
export function retainedFileKey(reference: string): string | null {
	if (!reference.startsWith('/v1/files/') || /[?#\\\u0000-\u001f\u007f]/.test(reference))
		return null;
	try {
		const segments = reference.slice('/v1/files/'.length).split('/').map(decodeURIComponent);
		if (segments.some((segment) => segment.includes('/'))) return null;
		const key = segments.join('/');
		return validKey(key) ? key : null;
	} catch {
		return null;
	}
}
export function createRetainedFileResolver(
	connection: { endpoint: string; token: string },
	fetcher: typeof fetch = fetch
): RetainedFileResolver {
	const endpoint = createHttpHub(connection.endpoint, connection.token, fetcher).endpoint;
	return async (key, signal) => {
		if (!validKey(key)) throw Error('Invalid retained file key.');
		signal?.throwIfAborted();
		let response: Response;
		try {
			response = await fetcher(
				endpoint + '/v1/files/' + key.split('/').map(encodeURIComponent).join('/'),
				{
					headers: { Authorization: `Bearer ${connection.token}` },
					credentials: 'omit',
					redirect: 'error',
					signal
				}
			);
		} catch {
			throw Error('File request failed. Check the connection and retry.');
		}
		if (!response.ok)
			throw Error(`File HTTP ${response.status}. Retry after checking your connection and access.`);
		if (Number(response.headers.get('Content-Length')) > maximumBytes)
			throw Error('File exceeds the 128 MB viewing limit.');
		const reader = response.body?.getReader();
		const chunks: Uint8Array<ArrayBuffer>[] = [];
		let size = 0;
		try {
			while (reader) {
				signal?.throwIfAborted();
				const { done, value } = await reader.read();
				if (done) break;
				size += value.byteLength;
				if (size > maximumBytes) throw Error('File exceeds the 128 MB viewing limit.');
				chunks.push(new Uint8Array(value));
			}
		} finally {
			await reader?.cancel();
		}
		signal?.throwIfAborted();
		const contentType =
			response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() ||
			'application/octet-stream';
		const url = URL.createObjectURL(new Blob(chunks, { type: contentType }));
		let disposed = false;
		return {
			url,
			contentType,
			dispose() {
				if (!disposed) {
					disposed = true;
					URL.revokeObjectURL(url);
				}
			}
		};
	};
}
export function isInlineImage(contentType: string): boolean {
	return ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/bmp'].includes(
		contentType
	);
}
