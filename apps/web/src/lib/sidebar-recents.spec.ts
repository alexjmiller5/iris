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
const pendingOf = (destination: Destination): RecentEntry => ({
	destination,
	label: destination.row ?? destination.view ?? destination.table ?? '',
	context: destination.row
		? `Record · ${destination.table}`
		: destination.view
			? `View · ${destination.table}`
			: 'Table',
	trash: false,
	loading: true,
	unavailable: null
});
test('revisiting moves only that exact destination first and caps history at eight', () => {
	let items: RecentEntry[] = [];
	for (let i = 0; i < 10; i++)
		items = rememberRecent(items, entry({ table: 'things', view: null, row: String(i) }, `#${i}`));
	expect(items.map((e) => e.destination.row)).toEqual(['9', '8', '7', '6', '5', '4', '3', '2']);
	items = rememberRecent(items, entry({ table: 'things', view: null, row: '5' }, 'Renamed'));
	expect(items.map((e) => e.destination.row)).toEqual(['5', '9', '8', '7', '6', '4', '3', '2']);
	expect(items[0].label).toBe('Renamed');
	expect(rememberRecent(items, pendingOf({ table: null, view: null, row: null }))).toEqual(items);
});
test('stored entries carry their display snapshot but never unrelated fields', () => {
	const items = rememberRecent(
		rememberRecent([entry(table, 'things')], entry(view, 'A view')),
		entry(row, 'A title')
	);
	expect(items.map((e) => e.destination)).toEqual([row, view, table]);
	const contaminated = {
		...entry(row, 'A title'),
		destination: { ...row, token: 'Do not persist this credential' },
		token: 'Do not persist this credential either'
	} as RecentEntry;
	const stored = JSON.parse(serializeRecents([contaminated, entry(table, 'things')]));
	expect(stored).toEqual({
		version: 2,
		entries: [
			{ ...row, label: 'A title', context: 'Record · things', trash: false, unavailable: null },
			{ ...table, label: 'things', context: 'Record · things', trash: false, unavailable: null }
		]
	});
	expect(parseRecents(serializeRecents(items))).toEqual(items);
});
test('a never-resolved entry is stored as its identity only and reopens pending', () => {
	const stored = JSON.parse(serializeRecents([pendingOf(row)]));
	expect(stored.entries).toEqual([row]);
	expect(parseRecents(JSON.stringify(stored))).toEqual([pendingOf(row)]);
});
test('unavailable entries keep their last label and reason across reopening', () => {
	const gone = { ...entry(row, 'Last title'), unavailable: 'Not available in this replica' };
	expect(parseRecents(serializeRecents([gone]))).toEqual([gone]);
});
test('version 1 tuple-only history reopens without losing entries', () => {
	expect(
		parseRecents(JSON.stringify({ version: 1, entries: [row, { ...table, label: 'Old label' }] }))
	).toEqual([pendingOf(row), pendingOf(table)]);
});
test('parser rejects malformed/versioned roots but keeps valid entries from a partial preference', () => {
	expect(parseRecents(null)).toEqual([]);
	for (const raw of [
		'{',
		'[]',
		'{"version":3,"entries":[]}',
		'{"version":1,"entries":{}}',
		'{"version":2,"entries":{}}'
	])
		expect(() => parseRecents(raw)).toThrow();
	const snapshot = { label: 'Title', context: 'Record · things', trash: false, unavailable: null };
	expect(
		parseRecents(
			JSON.stringify({
				version: 2,
				entries: [
					{ ...row, ...snapshot },
					{ ...row, ...snapshot, label: 'Duplicate' },
					{ ...table, ...snapshot, label: 3 },
					{ ...view, ...snapshot, trash: 'yes' },
					{ table: '', view: null, row: null, ...snapshot },
					{ table: 'things', view: 3, row: null },
					{ table: 'things', view: null },
					{ table: null, view: null, row: 'id' }
				]
			})
		)
	).toEqual([{ destination: row, ...snapshot, loading: false }, pendingOf(table), pendingOf(view)]);
});
test('parser bounds oversized input while retaining newest order', () => {
	const raw = JSON.stringify({
		version: 2,
		entries: Array.from({ length: 12 }, (_, i) => ({ table: 'things', view: null, row: String(i) }))
	});
	expect(parseRecents(raw).map((e) => e.destination.row)).toEqual([
		'0',
		'1',
		'2',
		'3',
		'4',
		'5',
		'6',
		'7'
	]);
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
test('a plain table link is a table visit even though it opens the default view', () => {
	// Core resolves a table without a view to its default saved view.
	const opened = {
		table: 'things',
		catalog: { tables: [{ id: 'things', display: 'heading' }], properties: [], rules: [] },
		view: { id: 'default-view', name: 'Default view' },
		row: null
	};
	expect(describeRecent(table, opened as never)).toMatchObject({
		label: 'things',
		context: 'Table'
	});
	// Only a chosen view names itself, and only a chosen view joins a record's context.
	expect(describeRecent({ ...table, view: 'default-view' }, opened as never)).toMatchObject({
		label: 'Default view',
		context: 'View · things'
	});
	const record = { ...table, row: 'r' };
	expect(
		describeRecent(record, { ...opened, row: { id: 'r', heading: 'Title' } } as never)
	).toMatchObject({ label: 'Title', context: 'Record · things' });
});
test('unavailable local entries retain their position, identity and last label', async () => {
	let visible: RecentEntry[] = [];
	await loadRecentEntries(
		[entry(row, 'Last title'), pendingOf(table)],
		async (d) => {
			if (d.row) throw Error('Not available in this replica');
			return entry(d, 'things');
		},
		(next) => (visible = next),
		() => true
	);
	expect(visible.map((e) => e.destination)).toEqual([row, table]);
	expect(visible[0]).toMatchObject({
		label: 'Last title',
		loading: false,
		unavailable: 'Not available in this replica'
	});
	expect(visible[1]).toMatchObject({ loading: false, unavailable: null, label: 'things' });
});
test('a refresh starts from the shown snapshots and publishes only real changes', async () => {
	const published: RecentEntry[][] = [];
	const shown = [entry(row, 'Same title'), entry(view, 'Old view name'), entry(table, 'things')];
	await loadRecentEntries(
		shown,
		async (d) =>
			d.view && !d.row ? entry(d, 'Renamed view') : entry(d, d.row ? 'Same title' : 'things'),
		(next) => published.push(next),
		() => true
	);
	expect(published.map((list) => list.map((e) => e.label))).toEqual([
		['Same title', 'Renamed view', 'things']
	]);
	await loadRecentEntries(
		shown.slice(0, 1),
		async (d) => entry(d, 'Same title'),
		(next) => published.push(next),
		() => true
	);
	expect(published).toHaveLength(1);
});
test.each([false, true])(
	'late label success/failure cannot replace a changed workspace or removed entry: %s',
	async (fail) => {
		const held = deferred<RecentEntry>();
		let current = true;
		let visible: RecentEntry[] = [entry(row, 'Shown title'), entry(table, 'things')];
		let calls = 0;
		const pending = loadRecentEntries(
			visible,
			() => {
				calls++;
				return held.promise;
			},
			(next) => (visible = next),
			() => current
		);
		expect(visible[0]).toMatchObject({ label: 'Shown title', loading: false });
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
		const { displayName } = await import('iris-core/client');
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
