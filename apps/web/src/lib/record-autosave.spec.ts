import { expect, test } from 'vitest';
import {
	blockedBy,
	commitDelay,
	mergeRemote,
	withoutBlocked,
	MARKDOWN_DELAY,
	TYPING_DELAY
} from './record-autosave';

test('choices commit on change, typed fields after an idle pause, Markdown on its own timer', () => {
	for (const type of ['select', 'multi_select', 'bool', 'date', 'datetime', 'ref', 'multi_ref'])
		expect(commitDelay(type)).toBe(0);
	for (const type of ['text', 'number', 'int', 'url', 'email', 'phone', 'json', undefined])
		expect(commitDelay(type)).toBe(TYPING_DELAY);
	expect(TYPING_DELAY).toBe(500);
	expect(commitDelay('markdown')).toBe(MARKDOWN_DELAY);
});

test('a violation on a patched column blocks only that column at its current draft', () => {
	const patch = { id: 'n', title: 'Fine', size: 'abc' };
	expect(
		blockedBy([{ col: 'size', message: 'Must be a number.' }], patch, {
			title: 'Fine',
			size: 'abc'
		})
	).toEqual({ size: { value: 'abc', message: 'Must be a number.' } });
});

test('a violation the patch cannot isolate blocks nothing so the whole write stays failed', () => {
	const patch = { title: 'Only a title' };
	expect(blockedBy([{ col: 'status', message: 'Required.' }], patch, {})).toBeNull();
	expect(blockedBy([{ col: '', message: 'Rule failed.' }], { id: 'n', title: 'x' }, {})).toBeNull();
	expect(blockedBy(undefined, patch, {})).toBeNull();
});

test('blocked columns stay out of the patch until their draft changes', () => {
	const blocked = { size: { value: 'abc', message: 'Must be a number.' } };
	expect(withoutBlocked({ id: 'n', title: 'Fine', size: 'abc' }, blocked, { size: 'abc' })).toEqual(
		{
			id: 'n',
			title: 'Fine'
		}
	);
	expect(withoutBlocked({ id: 'n', size: 'abc' }, blocked, { size: 'abc' })).toBeNull();
	expect(withoutBlocked({ id: 'n', size: '12' }, blocked, { size: '12' })).toEqual({
		id: 'n',
		size: '12'
	});
	expect(withoutBlocked({}, {}, {})).toBeNull();
	expect(withoutBlocked({ title: 'New' }, {}, { title: 'New' })).toEqual({ title: 'New' });
});

test('a remote edit updates untouched fields and never the field being typed in', () => {
	const merged = mergeRemote(
		{ title: 'Typing here', status: 'Open', body: 'Local unsaved' },
		{ title: 'Typing here', status: 'Open', body: 'Saved body' },
		{ title: 'Remote title', status: 'Done', body: 'Remote body' },
		new Set(['title'])
	);
	expect(merged.values).toEqual({ title: 'Typing here', status: 'Done', body: 'Local unsaved' });
	expect(JSON.parse(merged.baseline)).toEqual({
		title: 'Remote title',
		status: 'Done',
		body: 'Remote body'
	});
});
