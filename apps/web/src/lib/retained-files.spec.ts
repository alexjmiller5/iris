import { expect, test, vi } from 'vitest';
import { retainedFileKey, createRetainedFileResolver } from './retained-files';

test('retained references decode an opaque key without allowing a remote origin or traversal', () => {
	expect(retainedFileKey('/v1/files/raw/diagram%20one.png')).toBe('raw/diagram one.png');
	for (const value of [
		'https://other.example/v1/files/a',
		'//other.example/a',
		'/v1/files/../a',
		'/v1/files/%2e%2e/a',
		'/v1/files/a%2fb',
		'/v1/files/a?token=x',
		'/v1/files/a#x',
		'/v1/files/%00',
		'/v1/files/a\\b'
	])
		expect(retainedFileKey(value)).toBeNull();
});
test('the enrolled endpoint alone receives credentials; object URLs have an explicit lifetime', async () => {
	const fetcher = vi.fn(
		async () => new Response('image bytes', { headers: { 'Content-Type': 'image/png' } })
	);
	const revoke = vi.spyOn(URL, 'revokeObjectURL');
	const resolve = createRetainedFileResolver(
		{ endpoint: 'https://hub.example/base', token: 'fixture-token' },
		fetcher
	);
	const file = await resolve('raw/diagram one.png');
	expect(fetcher).toHaveBeenCalledWith(
		'https://hub.example/base/v1/files/raw/diagram%20one.png',
		expect.objectContaining({
			redirect: 'error',
			credentials: 'omit',
			headers: { Authorization: 'Bearer fixture-token' }
		})
	);
	expect(file.contentType).toBe('image/png');
	expect(file.url).toMatch(/^blob:/);
	file.dispose();
	file.dispose();
	expect(revoke).toHaveBeenCalledTimes(1);
	await expect(resolve('https://other.example/a')).rejects.toThrow(/key/i);
	expect(fetcher).toHaveBeenCalledTimes(1);
	revoke.mockRestore();
});
test.each([403, 404])(
	'missing or denied bytes can be retried without disclosing URLs (%s)',
	async (status) => {
		const fetcher = vi
			.fn()
			.mockResolvedValueOnce(new Response('', { status }))
			.mockResolvedValue(new Response('ok'));
		const resolve = createRetainedFileResolver(
			{ endpoint: 'https://hub.example', token: 'fixture-token' },
			fetcher
		);
		await expect(resolve('raw/a')).rejects.toThrow(`File HTTP ${status}`);
		const file = await resolve('raw/a');
		file.dispose();
		expect(fetcher).toHaveBeenCalledTimes(2);
	}
);

test('image previews reject oversized headers before reading or decoding, while downloads keep the original limit', async () => {
	const resolve = createRetainedFileResolver(
		{ endpoint: 'https://hub.example', token: 'fixture-token' },
		async () =>
			new Response('original', {
				headers: { 'Content-Type': 'image/png', 'Content-Length': String(9 * 1024 * 1024) }
			})
	);
	await expect(resolve('raw/large.png', undefined, true)).rejects.toThrow(/8 MB/);
	const original = await resolve('raw/large.png');
	expect(original.contentType).toBe('image/png');
	original.dispose();
});

test('image previews enforce the byte limit when Content-Length is missing', async () => {
	let canceled = false;
	const resolve = createRetainedFileResolver(
		{ endpoint: 'https://hub.example', token: 'fixture-token' },
		async () =>
			new Response(
				new ReadableStream(
					{
						start(controller) {
							controller.enqueue(new Uint8Array(8 * 1024 * 1024 + 1));
						},
						cancel() {
							canceled = true;
						},
						pull(controller) {
							controller.close();
						}
					},
					{ highWaterMark: 0 }
				),
				{ headers: { 'Content-Type': 'image/png' } }
			)
	);
	await expect(resolve('raw/large.png', undefined, true)).rejects.toThrow(/8 MB/);
	expect(canceled).toBe(true);
});
