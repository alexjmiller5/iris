import { expect, test } from 'vitest';
import {
	entryKey,
	paletteEntries,
	selectEntry,
	loadDestinations,
	type NavigationState,
	type PaletteDestination
} from './command-palette';
import type { SavedViewRecord, SavedViewList } from 'life-ui-core/client';

const destinations: PaletteDestination[] = [
	{ kind: 'table', table: 'notes', label: 'notes' },
	{ kind: 'table', table: 'tasks', label: 'tasks' },
	{ kind: 'view', table: 'notes', id: 'one', label: 'Pinned' },
	{ kind: 'view', table: 'tasks', id: 'two', label: 'Pinned', unavailable: 'Unsupported version' }
];
const record = { table: 'notes', id: 'one', label: 'Pinned', excerpt: 'A record body' };
const view = (id: string, tbl: string): SavedViewRecord => ({
	id,
	tbl,
	name: 'Pinned',
	updated_at: '2026-01-01T00:00:00Z',
	deleted_at: null,
	definition: { version: 1, columns: ['title'] },
	view: { table: tbl },
	unavailable: null
});
const deferred = <T>() => {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	void promise.catch(() => {});
	return { promise, resolve, reject };
};

test('blank input offers navigation; label filtering leaves core record matches untouched', () => {
	expect(paletteEntries('  ', destinations, [])).toEqual(destinations);
	expect(paletteEntries('PIN', destinations, [record])).toEqual([
		destinations[2],
		destinations[3],
		{ kind: 'record', ...record }
	]);
	expect(paletteEntries(' NOTES ', destinations, [])).toEqual([destinations[0], destinations[2]]);
	// Core can match body text absent from the label. Never refilter those results.
	expect(paletteEntries('body', destinations, [record])).toEqual([{ kind: 'record', ...record }]);
});

test('kind/table/id identity keeps equally named records, tables and views distinct', () => {
	const entries = paletteEntries('', destinations, [record, { ...record, table: 'tasks' }]);
	expect(new Set(entries.map(entryKey)).size).toBe(6);
	expect(entryKey({ ...destinations[2], label: 'Renamed' })).toBe(entryKey(destinations[2]));
});

test('keyboard skips disabled views, wraps and keeps selection when late groups arrive', () => {
	const entries = paletteEntries('', destinations, [record]);
	const key = entryKey(entries[4]);
	expect(selectEntry(entries, key)).toBe(key);
	expect(selectEntry(entries, key, -1)).toBe(entryKey(destinations[2]));
	expect(selectEntry(entries, key, 1)).toBe(entryKey(destinations[0]));
	expect(selectEntry(entries, null, -1)).toBe(key);
	expect(selectEntry(entries, entryKey(destinations[3]))).toBe(entryKey(destinations[0]));
	expect(selectEntry([], key)).toBeNull();
	expect(selectEntry([destinations[3]], null)).toBeNull();
});

test('view lists load progressively once per table, preserving core disabled reasons', async () => {
	const first = deferred<SavedViewList>();
	const second = deferred<SavedViewList>();
	const calls: string[] = [];
	const states: NavigationState[] = [];
	const done = loadDestinations(
		['notes', 'tasks'],
		(table) => {
			calls.push(table);
			return table === 'notes' ? first.promise : second.promise;
		},
		(state) => states.push(state),
		() => true
	);
	expect(states[0]).toEqual({ destinations: destinations.slice(0, 2), loading: true, error: '' });
	expect(calls).toEqual(['notes']);
	first.resolve({ views: [view('one', 'notes')], unavailable: null });
	await first.promise;
	await Promise.resolve();
	expect(states.at(-1)?.destinations).toEqual(destinations.slice(0, 3));
	expect(calls).toEqual(['notes', 'tasks']);
	second.resolve({
		views: [
			{ ...view('two', 'tasks'), definition: null, view: null, unavailable: 'Unsupported version' }
		],
		unavailable: null
	});
	await done;
	expect(states.at(-1)).toEqual({ destinations, loading: false, error: '' });
});

test.each(['resolve', 'reject'] as const)(
	'closing ignores late %s and stops requesting other tables',
	async (settle) => {
		const pending = deferred<SavedViewList>();
		const states: NavigationState[] = [];
		const calls: string[] = [];
		let current = true;
		const done = loadDestinations(
			['notes', 'tasks'],
			(table) => {
				calls.push(table);
				return pending.promise;
			},
			(state) => states.push(state),
			() => current
		);
		current = false;
		if (settle === 'resolve') pending.resolve({ views: [view('old', 'notes')], unavailable: null });
		else pending.reject(new Error('Old failure'));
		await done;
		expect(states).toHaveLength(1);
		expect(calls).toEqual(['notes']);
	}
);

test('one failed list retains tables and other views with a visible error', async () => {
	const states: NavigationState[] = [];
	await loadDestinations(
		['notes', 'tasks'],
		async (table) => {
			if (table === 'notes') throw new Error('List failed');
			return { views: [view('two', 'tasks')], unavailable: null };
		},
		(state) => states.push(state),
		() => true
	);
	expect(states.at(-1)).toMatchObject({ loading: false, error: 'notes: List failed' });
	expect(states.at(-1)?.destinations).toEqual([
		...destinations.slice(0, 2),
		{ kind: 'view', table: 'tasks', id: 'two', label: 'Pinned' }
	]);
});

test('unavailable storage is shown without inventing views or suppressing tables', async () => {
	let state: NavigationState | undefined;
	await loadDestinations(
		['notes'],
		async () => ({ views: [], unavailable: 'Sync the views schema' }),
		(result) => (state = result),
		() => true
	);
	expect(state).toEqual({
		destinations: [destinations[0]],
		loading: false,
		error: 'notes: Sync the views schema'
	});
});
