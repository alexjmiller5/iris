import { expect, test } from 'vitest';
import { parseCapture, readCaptureArtifact, archiveDocument } from './page-capture';
import { createRetainedFileResolver } from './retained-files';

const digest = async (bytes: Uint8Array<ArrayBuffer>) =>
	Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)))
		.map((x) => x.toString(16).padStart(2, '0'))
		.join('');
async function fixture() {
	const bytes = new TextEncoder().encode('<h1>Archived fixture</h1>');
	const sha = await digest(bytes);
	return {
		bytes,
		row: {
			id: 'attempt-1',
			capture_id: 'capture-1',
			event_id: 'event-1',
			subscription_id: 'subscription-1',
			source_table: 'articles',
			source_row_id: 'row-1',
			source_column: 'url',
			source_url: 'https://example.test/',
			observed_source_revision: '{}',
			attempted_at: '2026-01-01T00:00:00.000Z',
			captured_at: '2026-01-01T00:00:01.000Z',
			status: 'partial',
			failure_code: 'partial',
			failure_detail:
				'Incomplete archive: 2 resource requests could not be saved; 1 section was still loading.',
			html_key: 'captures/page.html',
			html_mime: 'text/html',
			html_bytes: bytes.length,
			html_sha256: sha,
			png_key: 'captures/page.png',
			png_mime: 'image/png',
			png_bytes: bytes.length,
			png_sha256: sha
		}
	};
}

test('an explicit attempt retains warnings and invalid original text, never guesses by table name', async () => {
	const { row } = await fixture();
	expect(parseCapture(row).warning).toBe(row.failure_detail);
	const terminal: Record<string, unknown> = {
		...row,
		status: 'unsupported',
		failure_code: 'invalid_url',
		failure_detail: null,
		captured_at: null,
		source_url: '  '
	};
	for (const kind of ['html', 'png'])
		for (const field of ['key', 'mime', 'bytes', 'sha256']) terminal[`${kind}_${field}`] = null;
	expect(parseCapture(terminal).sourceURL).toBeNull();
	expect(parseCapture(terminal).originalURL).toBe('  ');
	expect(() => parseCapture({ ...terminal, source_url: '' })).toThrow();
	expect(() => parseCapture({ id: 'row', html_key: 'captures/page.html' })).toThrow();
	expect(() =>
		parseCapture({ ...row, failure_detail: 'Incomplete archive: 0 sections were still loading.' })
	).toThrow();
	expect(() => parseCapture({ ...row, html_key: '../page.html' })).toThrow();
	expect(() => parseCapture({ ...terminal, html_key: 'captures/page.html' })).toThrow();
});

test('artifact reads reauthorize through the host resolver and verify bytes before use', async () => {
	const { row, bytes } = await fixture();
	const capture = parseCapture(row);
	let requests = 0;
	const resolver = createRetainedFileResolver(
		{ endpoint: 'https://hub.example', token: 'synthetic' },
		async (_url, init) => {
			requests++;
			expect(init?.redirect).toBe('error');
			return new Response(bytes, { headers: { 'Content-Type': 'text/html' } });
		}
	);
	const result = await readCaptureArtifact(capture, 'html', resolver, new AbortController().signal);
	expect(await result.text()).toBe('<h1>Archived fixture</h1>');
	await readCaptureArtifact(capture, 'html', resolver, new AbortController().signal);
	expect(requests).toBe(2);
	const wrong = createRetainedFileResolver(
		{ endpoint: 'https://hub.example', token: 'synthetic' },
		async () => new Response('tampered', { headers: { 'Content-Type': 'text/html' } })
	);
	await expect(
		readCaptureArtifact(capture, 'html', wrong, new AbortController().signal)
	).rejects.toThrow(/match/);
	await expect(
		readCaptureArtifact(capture, 'html', resolver, new AbortController().signal, 1)
	).rejects.toThrow(/limit/);
	expect(requests).toBe(2);
});

test('archive policy precedes hostile markup without altering stored bytes', () => {
	const hostile =
		'<meta http-equiv="refresh" content="0;url=https://example.test"><script>alert(1)</script>';
	const document = archiveDocument(hostile);
	expect(document.indexOf("default-src 'none'")).toBeLessThan(document.indexOf(hostile));
	expect(document).toContain("form-action 'none'");
	expect(document).toContain("base-uri 'none'");
	expect(document).toContain(hostile);
});
