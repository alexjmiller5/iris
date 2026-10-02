import { expect, test } from 'vitest';
import { parseEditorDocument } from './editor-island';

test('native document input is copied and retains source exactly', () => {
	const input = { id: 'draft-1', value: '# A heading\n', label: 'Body', readOnly: false };
	const parsed = parseEditorDocument(input);
	input.value = 'changed';
	expect(parsed).toEqual({ id: 'draft-1', value: '# A heading\n', label: 'Body', readOnly: false });
});
test.each([
	null,
	[],
	{},
	{ id: '', value: '', label: 'Body', readOnly: false },
	{ id: '1', value: 9, label: 'Body', readOnly: false },
	{ id: '1', value: '', label: '', readOnly: false },
	{ id: '1', value: '', label: 'Body', readOnly: 'false' }
])('malformed native document cannot replace an open draft (%j)', (input) => {
	expect(() => parseEditorDocument(input)).toThrow(/editor document/i);
});
