import { createHttpHub } from 'life-ui-core/client';

export interface RetainedFile {
	url: string;
	contentType: string;
	dispose(): void;
}
export type RetainedFileResolver = (
	key: string,
	signal?: AbortSignal,
	preview?: boolean
) => Promise<RetainedFile>;

/** Browser decoding owns its transient allocation; only a bounded static raster is displayed. */
async function imagePreview(blob: Blob, signal?: AbortSignal): Promise<Blob> {
	const url = URL.createObjectURL(blob);
	const image = new Image();
	let canvas: HTMLCanvasElement | undefined;
	let abort: (() => void) | undefined;
	try {
		signal?.throwIfAborted();
		image.decoding = 'async';
		await new Promise<void>((resolve, reject) => {
			image.onload = () => resolve();
			image.onerror = () => reject(Error('The image could not be decoded.'));
			abort = () => reject(Error('Image request canceled.'));
			signal?.addEventListener('abort', abort, { once: true });
			image.src = url;
		});
		signal?.throwIfAborted();
		const width = image.naturalWidth,
			height = image.naturalHeight;
		if (!(
			width > 0 &&
			height > 0 &&
			width <= 100_000 &&
			height <= 100_000 &&
			width * height <= 100_000_000
		))
			throw Error('Image dimensions exceed the preview limit.');
		const scale = Math.min(1, 1024 / Math.max(width, height));
		canvas = document.createElement('canvas');
		canvas.width = Math.max(1, Math.round(width * scale));
		canvas.height = Math.max(1, Math.round(height * scale));
		const context = canvas.getContext('2d');
		if (!context) throw Error('Image preview is unavailable.');
		context.drawImage(image, 0, 0, canvas.width, canvas.height);
		const result = await new Promise<Blob>((resolve, reject) =>
			canvas!.toBlob(
				(value) => (value ? resolve(value) : reject(Error('Image preview is unavailable.'))),
				'image/png'
			)
		);
		signal?.throwIfAborted();
		return result;
	} finally {
		if (abort) signal?.removeEventListener('abort', abort);
		image.onload = null;
		image.onerror = null;
		image.src = '';
		URL.revokeObjectURL(url);
		if (canvas) canvas.width = canvas.height = 0;
	}
}

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
	return async (key, signal, preview = false) => {
		const maximumBytes = (preview ? 8 : 128) * 1024 * 1024;
		const tooLarge = `File exceeds the ${preview ? 8 : 128} MB ${preview ? 'preview' : 'viewing'} limit.`;
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
		let contentType =
			response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() ||
			'application/octet-stream';
		if (Number(response.headers.get('Content-Length')) > maximumBytes) {
			await response.body?.cancel();
			throw Error(tooLarge);
		}
		if (preview && !isInlineImage(contentType)) {
			await response.body?.cancel();
			throw Error('This file cannot be displayed as an image.');
		}
		const reader = response.body?.getReader();
		const chunks: Uint8Array<ArrayBuffer>[] = [];
		let size = 0;
		try {
			while (reader) {
				signal?.throwIfAborted();
				const { done, value } = await reader.read();
				if (done) break;
				size += value.byteLength;
				if (size > maximumBytes) throw Error(tooLarge);
				chunks.push(new Uint8Array(value));
			}
		} finally {
			await reader?.cancel();
		}
		signal?.throwIfAborted();
		let blob = new Blob(chunks, { type: contentType });
		if (preview) {
			blob = await imagePreview(blob, signal);
			contentType = blob.type;
		}
		const url = URL.createObjectURL(blob);
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
export async function retainedBlob(
	blob: Blob,
	signal?: AbortSignal,
	preview = false
): Promise<RetainedFile> {
	signal?.throwIfAborted();
	if (blob.size > (preview ? 8 : 128) * 1024 * 1024)
		throw Error('File exceeds the viewing size limit.');
	if (preview) {
		if (!isInlineImage(blob.type)) throw Error('This file cannot be displayed as an image.');
		blob = await imagePreview(blob, signal);
	}
	signal?.throwIfAborted();
	const url = URL.createObjectURL(blob);
	let disposed = false;
	return {
		url,
		contentType: blob.type,
		dispose() {
			if (!disposed) {
				disposed = true;
				URL.revokeObjectURL(url);
			}
		}
	};
}
export function isInlineImage(contentType: string): boolean {
	return ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/bmp'].includes(
		contentType
	);
}
