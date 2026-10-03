import { expect, test } from 'vitest';
import {
	describeRecent,
	loadRecentEntries,
	parseRecents,
	recentKey,
	rememberRecent,
	serializeRecents,
	type RecentEntry
} from './sidebar-recents';
import type { Destination } from './workspace-navigation';

const table: Destination = { table: 'things', view: null, row: null };
const view: Destination = { table: 'things', view: 'view/+?#%', row: null };
const row: Destination = { table: 'things', view: 'view/+?#%', row: 'row & café/#' };
const entry = (destination: Destination, label: string): RecentEntry => ({
	destination,
	label,
	context: 'Record · things',
	trash: false,
	loading: false,
	unavailable: null
});
function deferred<T>() {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	return { promise, resolve, reject };
}

test('exact opaque tuples distinguish table, view and row contexts without delimiter collisions', () => {
	expect(
		new Set(
			[
				table,
				view,
				row,
				{ ...row, view: null },
				{ table: 'things|x', view: null, row: 'y' },
				{ table: 'things', view: null, row: 'x|y' }
			].map(recentKey)
		).size
	).toBe(6);
});
test('revisiting moves only that exact destination first and caps history at eight', () => {
	let items: Destination[] = [];
	for (let i = 0; i < 10; i++)
		items = rememberRecent(items, { table: 'things', view: null, row: String(i) });
	expect(items.map((d) => d.row)).toEqual(['9', '8', '7', '6', '5', '4', '3', '2']);
	items = rememberRecent(items, { table: 'things', view: null, row: '5' });
	expect(items.map((d) => d.row)).toEqual(['5', '9', '8', '7', '6', '4', '3', '2']);
	expect(rememberRecent(items, { table: null, view: null, row: null })).toEqual(items);
});
test('table/view/record entries coexist and serialized preferences contain identifiers only', () => {
	const items = rememberRecent(rememberRecent([table], view), row);
	expect(items).toEqual([row, view, table]);
	const contaminated = {
		...row,
		label: 'Do not persist this title',
		token: 'Do not persist this credential'
	};
	expect(JSON.parse(serializeRecents([contaminated, table]))).toEqual({
		version: 1,
		entries: [row, table]
	});
	expect(parseRecents(serializeRecents(items))).toEqual(items);
});
test('parser rejects malformed/versioned roots but keeps valid entries from a partial preference', () => {
	expect(parseRecents(null)).toEqual([]);
	for (const raw of ['{', '[]', '{"version":2,"entries":[]}', '{"version":1,"entries":{}}'])
		expect(() => parseRecents(raw)).toThrow();
	expect(
		parseRecents(
			JSON.stringify({
				version: 1,
				entries: [
					row,
					row,
					{ ...table, label: 'Old label' },
					{ table: '', view: null, row: null },
					{ table: 'things', view: 3, row: null },
					{ table: 'things', view: null },
					{ table: null, view: null, row: 'id' }
				]
			})
		)
	).toEqual([row, table]);
});
test('parser bounds oversized input while retaining newest order', () => {
	const raw = JSON.stringify({
		version: 1,
		entries: Array.from({ length: 12 }, (_, i) => ({ table: 'things', view: null, row: String(i) }))
	});
	expect(parseRecents(raw).map((d) => d.row)).toEqual(['0', '1', '2', '3', '4', '5', '6', '7']);
});
test('labels and trash state come from the freshly resolved catalog/view/full row', () => {
	const resolved = {
		table: 'things',
		catalog: { tables: [{ id: 'things', display: 'heading' }], properties: [], rules: [] },
		view: { id: view.view, name: 'Current view' },
		row: { id: row.row, heading: 'Current title', deleted_at: '2026-01-01' }
	};
	expect(describeRecent(row, resolved as never)).toMatchObject({
		label: 'Current title',
		context: 'Record · things · Current view',
		trash: true,
		unavailable: null
	});
	expect(describeRecent(view, { ...resolved, row: null } as never)).toMatchObject({
		label: 'Current view',
		trash: false
	});
	expect(describeRecent(table, { ...resolved, row: null, view: null } as never)).toMatchObject({
		label: 'things',
		trash: false
	});
});
test('unavailable local entries retain their position and identity instead of being pruned', async () => {
	let visible: RecentEntry[] = [];
	await loadRecentEntries(
		[row, table],
		async (d) => {
			if (d.row) throw Error('Not available in this replica');
			return entry(d, 'things');
		},
		(next) => (visible = next),
		() => true
	);
	expect(visible.map((e) => e.destination)).toEqual([row, table]);
	expect(visible[0]).toMatchObject({
		loading: false,
		unavailable: 'Not available in this replica'
	});
	expect(visible[1]).toMatchObject({ loading: false, unavailable: null, label: 'things' });
});
test.each([false, true])(
	'late label success/failure cannot replace a changed workspace or removed entry: %s',
	async (fail) => {
		const held = deferred<RecentEntry>();
		let current = true;
		let visible: RecentEntry[] = [];
		let calls = 0;
		const pending = loadRecentEntries(
			[row, table],
			() => {
				calls++;
				return held.promise;
			},
			(next) => (visible = next),
			() => current
		);
		expect(visible[0]?.loading).toBe(true);
		current = false;
		visible = [entry(table, 'New workspace')];
		if (fail) held.reject(Error('Old failure'));
		else held.resolve(entry(row, 'Old title'));
		await pending;
		expect(visible.map((e) => e.label)).toEqual(['New workspace']);
		expect(calls).toBe(1);
	}
);

test.each(['', '   ', { nested: 'value' }, null])(
	'recent labels use the shared record display policy: %s',
	async (title) => {
		const { displayName } = await import('life-ui-core/client');
		const record = { id: row.row, heading: title };
		const resolved = {
			table: 'things',
			catalog: { tables: [{ id: 'things', display: 'heading' }], properties: [], rules: [] },
			view: null,
			row: record
		};
		expect(describeRecent(row, resolved as never).label).toBe(
			displayName(record as never, 'heading')
		);
	}
);
