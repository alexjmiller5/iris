import { expect, test } from 'vitest';
import {
	cellPatch,
	recordPatch,
	createCellEditor,
	duplicateValues,
	moveCell,
	rawValue
} from './record-grid';

const row = { id: 'a', title: 'Before', qty: 42, updated_at: '2026-01-01T00:00:00.000Z' };
const deferred = <T>() => {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	return { promise, resolve, reject };
};

test('cursor follows row and column identities after reordering and wraps Tab at the row edge', () => {
	const rows = [{ id: 'b' }, { id: 'a' }];
	expect(moveCell(rows, ['qty', 'title'], { rowId: 'a', column: 'qty' }, 1, 0)).toEqual({
		rowId: 'a',
		column: 'title'
	});
	expect(moveCell(rows, ['qty', 'title'], { rowId: 'b', column: 'title' }, 1, 0, true)).toEqual({
		rowId: 'a',
		column: 'qty'
	});
	expect(moveCell(rows, ['qty', 'title'], { rowId: 'a', column: 'title' }, 1, 0, true)).toBeNull();
});

test.each([
	['int', '', null],
	['number', '0', 0],
	['bool', '0', 0],
	['bool', '1', 1],
	['number', 'invalid', 'invalid'],
	['number', ' ', null],
	['int', '-', '-'],
	['text', '  ', '  '],
	['json', '{"a":1}', '{"a":1}'],
	['multi_select', '["unknown"]', '["unknown"]']
])('cell patch preserves %s input %s for the shared writer', (type, raw, value) => {
	expect(
		cellPatch(
			{ col: 'qty', type: String(type) },
			{ cell: { rowId: 'a', column: 'qty' }, baseline: row, raw: String(raw) }
		)
	).toEqual({ id: 'a', qty: value });
});

test('duplicate copies ordinary fields including set-once fields, without identity or generated values', () => {
	expect(
		duplicateValues(
			[
				{ col: 'id' },
				{ col: 'qty' },
				{ col: 'code', immutable: true },
				{ col: 'derived', derived_by: 'x' },
				{ col: 'old', deprecated: true }
			],
			{ ...row, code: 'code', derived: 'generated', old: 'old' }
		)
	).toEqual({ qty: '42', code: 'code' });
	expect(rawValue(false)).toBe('false');
	expect(rawValue(['retired', 'new'])).toBe('["retired","new"]');
});

test('a later lookup owns the editor and an old success or error cannot replace it', async () => {
	const editor = createCellEditor(() => {}),
		old = deferred<typeof row>();
	const first = editor.begin({ rowId: 'a', column: 'title' }, () => old.promise);
	await editor.begin({ rowId: 'b', column: 'qty' }, async () => ({ ...row, id: 'b', qty: 7 }));
	old.resolve(row);
	await first;
	expect(editor.state.edit).toMatchObject({ cell: { rowId: 'b', column: 'qty' }, raw: '7' });
	const delayed = deferred<typeof row>();
	const pending = editor.begin({ rowId: 'a', column: 'title' }, () => delayed.promise);
	editor.discard();
	delayed.reject(new Error('old lookup'));
	await pending;
	expect(editor.state.edit).toBeNull();
	expect(editor.state.error).toBe('');
});

test('rejected commit keeps raw input and the original revision; retry returns its real receipt', async () => {
	const editor = createCellEditor(() => {});
	await editor.begin({ rowId: 'a', column: 'qty' }, async () => row);
	editor.change('44');
	expect(
		await editor.commit(async () => {
			throw new Error('revision conflict');
		})
	).toBe(false);
	expect(editor.state.edit).toMatchObject({ raw: '44', baseline: { updated_at: row.updated_at } });
	expect(editor.state.error).toBe('revision conflict');
	const calls: unknown[] = [];
	expect(
		await editor.commit(async (edit) => {
			calls.push(edit);
			return { ...row, qty: 44 };
		})
	).toEqual({ ...row, qty: 44 });
	expect(calls).toEqual([{ cell: { rowId: 'a', column: 'qty' }, baseline: row, raw: '44' }]);
	expect(editor.state.edit).toBeNull();
});

test('a committed cell returns the complete writer receipt for a following row action', async () => {
	const editor = createCellEditor(() => {});
	await editor.begin({ rowId: 'a', column: 'qty' }, async () => row);
	editor.change('44');
	const stored = { ...row, qty: 44, updated_at: '2026-01-02T00:00:00.000Z', derived: 'new' };
	const receipt = await editor.commit(async () => stored);
	expect(receipt).toEqual(stored);
	expect(editor.state.edit).toBeNull();
	// A later action with no edit must never reuse a prior receipt.
	expect(
		await editor.commit(async () => {
			throw Error('No write expected');
		})
	).toBe(true);
});

test('pending commits cannot discard, type or submit twice, and unchanged cells do not write', async () => {
	const editor = createCellEditor(() => {}),
		pending = deferred<typeof row>();
	let calls = 0;
	await editor.begin({ rowId: 'a', column: 'qty' }, async () => row);
	expect(
		await editor.commit(async () => {
			calls++;
			return row;
		})
	).toBe(true);
	expect(calls).toBe(0);
	await editor.begin({ rowId: 'a', column: 'qty' }, async () => row);
	editor.change('43');
	const saving = editor.commit(() => {
		calls++;
		return pending.promise;
	});
	expect(editor.discard()).toBe(false);
	editor.change('45');
	expect(
		await editor.commit(async () => {
			calls++;
			return row;
		})
	).toBe(false);
	expect(editor.state.edit?.raw).toBe('43');
	pending.resolve(row);
	await saving;
	expect(calls).toBe(1);
});

test('creation omits untouched defaults but preserves explicitly cleared and copied null fields', () => {
	const properties = [
		{ col: 'title', type: 'text' },
		{ col: 'qty', type: 'int' },
		{ col: 'active', type: 'bool' }
	];
	expect(
		recordPatch(
			properties,
			{ title: 'New', qty: '', active: '0' },
			null,
			new Set(['title', 'active'])
		)
	).toEqual({
		title: 'New',
		active: 0
	});
	expect(
		recordPatch(
			properties,
			{ title: 'Copy', qty: '', active: '0' },
			null,
			new Set(['title', 'active', 'qty'])
		)
	).toEqual({ title: 'Copy', qty: null, active: 0 });
});

test('record form serializes only changed user-editable fields using the same value conversion as cells', () => {
	expect(
		recordPatch(
			[
				{ col: 'title' },
				{ col: 'qty', type: 'int' },
				{ col: 'fixed', immutable: true },
				{ col: 'derived', derived_by: 'source' }
			],
			{ title: 'Before', qty: 'invalid', fixed: 'changed', derived: 'changed' },
			{ ...row, fixed: 'original', derived: 'original' },
			new Set()
		)
	).toEqual({ id: 'a', qty: 'invalid' });
});

test('creation previews never pin an untouched default', () => {
	expect(
		recordPatch([{ col: 'status', default_value: 'Old' }], { status: 'Old' }, null, new Set())
	).toEqual({});
	expect(recordPatch([{ col: 'status' }], { status: '' }, null, new Set(['status']))).toEqual({
		status: null
	});
});

test('untouched copied scalars preserve empty strings, null, zero and JSON bytes', () => {
	const props = [
		{ col: 'body', type: 'markdown' },
		{ col: 'nil' },
		{ col: 'zero', type: 'int' },
		{ col: 'tags', type: 'multi_select' },
		{ col: 'fixed', immutable: true }
	];
	const copied = { body: '', nil: null, zero: 0, tags: '[ "Unknown" ]', fixed: 'Code' };
	const draft = duplicateValues(props, copied);
	expect(recordPatch(props, draft, null, new Set(), copied)).toEqual(copied);
	expect(recordPatch(props, draft, null, new Set(['body']), copied)).toEqual({
		...copied,
		body: null
	});
	expect(recordPatch(props, { ...draft, body: 'Edited' }, null, new Set(['body']), copied)).toEqual(
		{ ...copied, body: 'Edited' }
	);
});

test('copy serialization rechecks catalog exclusions without losing set-once creation fields', () => {
	const copied = {
		id: 'source',
		created_at: 'old',
		updated_at: 'old',
		deleted_at: 'old',
		hub_at: 'old',
		generated: 'old',
		retired: 'old',
		unknown: 'old',
		code: 'Keep'
	};
	const properties = [
		{ col: 'id' },
		{ col: 'created_at' },
		{ col: 'updated_at' },
		{ col: 'deleted_at' },
		{ col: 'hub_at' },
		{ col: 'generated', derived_by: 'rule' },
		{ col: 'retired', deprecated: true },
		{ col: 'code', immutable: true }
	];
	const draft = Object.fromEntries(Object.entries(copied).map(([k, v]) => [k, rawValue(v)]));
	expect(recordPatch(properties, draft, null, new Set(), copied)).toEqual({ code: 'Keep' });
	expect(
		recordPatch(properties, draft, { id: 'saved', code: 'Before' }, new Set(), copied)
	).toEqual({ id: 'saved' });
});
