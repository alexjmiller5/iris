import { expect, test } from 'vitest';
import { markdownPatch } from './record-autosave';
import type { Property } from 'life-ui-core/client';
const properties: Property[] = [
	{ tbl: 'notes', col: 'body', type: 'markdown' },
	{ tbl: 'notes', col: 'title', type: 'text' }
];
test('autosaves only changed editable markdown, preserving explicit-save properties', () => {
	expect(
		markdownPatch(
			properties,
			{ body: 'Second', title: 'New title' },
			{ id: 'n', body: 'First', title: 'Old title' }
		)
	).toEqual({ id: 'n', body: 'Second' });
});
test('does not create a row before required fields have been saved', () => {
	expect(markdownPatch(properties, { body: 'Draft' }, null)).toBeNull();
});
test('does not queue unchanged or catalog-locked Markdown', () => {
	expect(
		markdownPatch(
			[{ ...properties[0], immutable: true }],
			{ body: 'Edited' },
			{ id: 'n', body: 'Original' }
		)
	).toBeNull();
	expect(markdownPatch(properties, { body: 'Same' }, { id: 'n', body: 'Same' })).toBeNull();
});
test('clearing Markdown persists SQL null and treats an existing null as empty', () => {
	expect(markdownPatch(properties, { body: '' }, { id: 'n', body: 'Old' })).toEqual({
		id: 'n',
		body: null
	});
	expect(markdownPatch(properties, { body: '' }, { id: 'n', body: null })).toBeNull();
});

test('a newly cataloged column outside the opened draft is left untouched', () => {
	expect(
		markdownPatch(properties, { title: 'Unsaved' }, { id: 'n', body: 'Existing hidden content' })
	).toBeNull();
});
