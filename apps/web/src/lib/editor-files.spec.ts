import { afterEach, expect, test, vi } from 'vitest';
import { editorFiles } from './editor-files';
import type { EditorMessage } from './editor-island';
afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});
test('host file requests work without secure-context crypto and reject stale document replies', async () => {
	vi.stubGlobal('crypto', {});
	const messages: EditorMessage[] = [];
	const files = editorFiles((message) => messages.push(message));
	const result = files.resolve('draft-1')('raw/a');
	const request = messages[0];
	expect(request?.type).toBe('file');
	if (!request || !('request' in request)) throw Error('No file request');
	files.receive({ ...request, id: 'old-draft', base64: btoa('wrong'), contentType: 'image/png' });
	files.receive({ ...request, base64: btoa('image'), contentType: 'image/png' });
	const file = await result;
	expect(file.contentType).toBe('image/png');
	expect(file.url).toMatch(/^blob:/);
	file.dispose();
	files.dispose();
});
test('canceled file requests and closed editors ignore late host bytes', async () => {
	const messages: EditorMessage[] = [];
	const files = editorFiles((message) => messages.push(message));
	const controller = new AbortController();
	const file = files.resolve('draft')('raw/a', controller.signal);
	const rejection = expect(file).rejects.toThrow(/canceled/);
	controller.abort();
	await rejection;
	files.receive({ ...messages[0], base64: btoa('late'), contentType: 'image/png' });
	const link = files.openLink('draft', 'https://example.com');
	const closed = expect(link).rejects.toThrow(/closed/);
	files.dispose();
	await closed;
});

test.each([
	{ contentType: 'image/svg+xml', base64: btoa('<svg/>') },
	{ contentType: 'image/png', base64: 'A'.repeat(12 * 1024 * 1024) }
])('host image replies reject unsafe MIME or oversized base64 before decoding', async (payload) => {
	const messages: EditorMessage[] = [];
	const files = editorFiles((message) => messages.push(message));
	const result = files.resolve('draft')('raw/image');
	const rejected = expect(result).rejects.toThrow(/image|file/i);
	const decode = vi.spyOn(globalThis, 'atob');
	files.receive({ ...messages[0], ...payload });
	await rejected;
	expect(decode).not.toHaveBeenCalled();
	decode.mockRestore();
	files.dispose();
});

test('core requests carry the operation and return only the host result for this document', async () => {
	const messages: EditorMessage[] = [];
	const files = editorFiles((message) => messages.push(message));
	const reply = files.core('draft', 'mentionLabels', { targets: [] });
	const request = messages[0];
	if (!request || !('request' in request)) throw Error('No core request');
	expect(request.type).toBe('core');
	expect(JSON.parse(request.value)).toEqual({ op: 'mentionLabels', args: { targets: [] } });
	files.receive({ ...request, id: 'other', result: ['stale'] });
	files.receive({ ...request, result: [] });
	expect(await reply).toEqual([]);
	const failed = files.core('draft', 'search', { text: 'x' });
	files.receive({ ...messages[1], error: 'Not allowed in the editor.' });
	await expect(failed).rejects.toThrow('Not allowed in the editor.');
});
