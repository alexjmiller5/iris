import { test, expect, vi } from 'vitest';
import { attachmentMarkdown, uploadAttachment, type Attachment } from './attachments';
const data = new Blob(['upload fixture'], { type: 'text/plain' });
const hash = Array.from(
	new Uint8Array(await crypto.subtle.digest('SHA-256', await data.arrayBuffer())),
	(b) => b.toString(16).padStart(2, '0')
).join('');
const entry: Attachment = {
	id: 'fixture',
	key: 'attachments/fixture',
	name: 'snow [x]\n☃.txt',
	mime: 'text/plain',
	bytes: 14,
	sha256: hash,
	state: 'queued',
	endpoint: null
};
const connection = { endpoint: 'https://hub.invalid/prefix', token: 'synthetic' };
test('attachment insertion preserves raw Markdown and escapes only the display label', () => {
	const source = '# Exact  source\r\n\nOriginal **body**  ';
	expect(attachmentMarkdown(entry, source)).toBe(
		source + '\n\n[snow \\[x\\] ☃.txt](</v1/files/attachments/fixture>)'
	);
});
test('create-only upload sends exact bytes through the enrolled host', async () => {
	const fetcher = vi.fn(async () =>
		Response.json({ key: entry.key, mime: entry.mime, bytes: 14, sha256: hash }, { status: 201 })
	);
	await uploadAttachment(connection, entry, data, fetcher);
	expect(fetcher).toHaveBeenCalledWith(
		'https://hub.invalid/prefix/v1/files/attachments/fixture',
		expect.objectContaining({
			method: 'PUT',
			body: data,
			credentials: 'omit',
			redirect: 'error',
			headers: expect.objectContaining({
				Authorization: 'Bearer synthetic',
				'If-None-Match': '*',
				'X-Content-SHA256': hash
			})
		})
	);
});
test('uncertain retry hashes actual existing object bytes', async () => {
	const fetcher = vi
		.fn()
		.mockResolvedValueOnce(new Response('', { status: 412 }))
		.mockResolvedValueOnce(
			new Response('upload fixture', {
				headers: { 'Content-Type': 'text/plain', 'Content-Length': '14' }
			})
		);
	await uploadAttachment(connection, entry, data, fetcher);
	expect(fetcher).toHaveBeenCalledTimes(2);
	expect(fetcher.mock.calls[1][1]).toMatchObject({
		credentials: 'omit',
		redirect: 'error',
		headers: { Authorization: 'Bearer synthetic' }
	});
	const corrupt = vi
		.fn()
		.mockResolvedValueOnce(new Response('', { status: 412 }))
		.mockResolvedValueOnce(
			new Response('wrong contents', { headers: { 'Content-Type': 'text/plain' } })
		);
	await expect(uploadAttachment(connection, entry, data, corrupt)).rejects.toThrow(/integrity/i);
});
test('a staged attachment bound to another hub is never uploaded there', async () => {
	const fetcher = vi.fn();
	await expect(
		uploadAttachment(connection, { ...entry, endpoint: 'https://other.invalid' }, data, fetcher)
	).rejects.toThrow();
	expect(fetcher).not.toHaveBeenCalled();
});
