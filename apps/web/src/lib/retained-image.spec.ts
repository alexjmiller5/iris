// @vitest-environment happy-dom
import { afterEach, expect, test, vi } from 'vitest';
import { createRetainedFileResolver } from './retained-files';

const originals: string[] = [];
afterEach(() => {
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
	originals.splice(0);
});

function decodedImage(width: number, height: number) {
	vi.stubGlobal(
		'Image',
		class {
			naturalWidth = width;
			naturalHeight = height;
			onload: (() => void) | null = null;
			onerror: (() => void) | null = null;
			set src(value: string) {
				if (value) {
					originals.push(value);
					queueMicrotask(() => this.onload?.());
				}
			}
		}
	);
}
const resolve = () =>
	createRetainedFileResolver(
		{ endpoint: 'https://hub.example', token: 'fixture-token' },
		async () => new Response('encoded image', { headers: { 'Content-Type': 'image/gif' } })
	);

test.each([
	[100001, 1],
	[20000, 6000],
	[0, 2]
])(
	'preview rejects decoded dimensions %i x %i and releases source bytes',
	async (width, height) => {
		decodedImage(width, height);
		vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue({
			drawImage() {}
		} as never);
		vi.spyOn(HTMLCanvasElement.prototype, 'toBlob').mockImplementation((callback, type) =>
			callback(new Blob(['frame'], { type }))
		);
		const revoked = vi.spyOn(URL, 'revokeObjectURL');
		await expect(resolve()('raw/image.gif', undefined, true)).rejects.toThrow(/image/i);
		expect(revoked).toHaveBeenCalledWith(originals[0]);
	}
);

test('preview flattens image frames into a proportional 1024px PNG and releases the original', async () => {
	decodedImage(2048, 1024);
	let canvas: HTMLCanvasElement | undefined;
	let drawn: number[] = [];
	vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(function (
		this: HTMLCanvasElement
	) {
		canvas = this;
		return {
			drawImage() {
				drawn = [canvas!.width, canvas!.height];
			}
		} as never;
	});
	vi.spyOn(HTMLCanvasElement.prototype, 'toBlob').mockImplementation(function (callback, type) {
		callback(new Blob(['static frame'], { type }));
	});
	const revoked = vi.spyOn(URL, 'revokeObjectURL');
	const preview = await resolve()('raw/image.gif', undefined, true);
	expect(drawn).toEqual([1024, 512]);
	expect(canvas?.width).toBe(0);
	expect(canvas?.height).toBe(0);
	expect(preview.contentType).toBe('image/png');
	expect(preview.url).not.toBe(originals[0]);
	expect(revoked).toHaveBeenCalledWith(originals[0]);
	preview.dispose();
	expect(revoked).toHaveBeenCalledWith(preview.url);
});

test('closing a preview while the browser is reading image metadata releases its object URL', async () => {
	vi.stubGlobal(
		'Image',
		class {
			onload = null;
			onerror = null;
			set src(value: string) {
				if (value) originals.push(value);
			}
		}
	);
	const revoked = vi.spyOn(URL, 'revokeObjectURL');
	const controller = new AbortController();
	const pending = resolve()('raw/image.gif', controller.signal, true);
	const canceled = expect(pending).rejects.toThrow(/cancel|abort/i);
	await vi.waitFor(() => expect(originals).toHaveLength(1));
	controller.abort();
	await canceled;
	expect(revoked).toHaveBeenCalledWith(originals[0]);
});
