import { expect, test } from 'vitest';
import { get } from 'svelte/store';
import * as feature from './incoming-references';
import type { ReferenceSource, ReferencedByPage } from 'iris-core/client';

const source: ReferenceSource = {
	table: 'entries',
	column: 'owner',
	label: 'Owner',
	type: 'ref',
	incomplete: false
};
const row = (id: string, label = id) => ({ record: { id }, label });
function create(
	readSources: () => Promise<ReferenceSource[]>,
	readPage: (source: ReferenceSource, offset: number) => Promise<ReferencedByPage>
) {
	expect(
		feature.createIncomingReferences,
		'Incoming relationship presentation is available'
	).toBeTypeOf('function');
	return feature.createIncomingReferences(readSources, readPage);
}
const deferred = <T>() => {
	let resolve!: (value: T) => void, reject!: (error: Error) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	void promise.catch(() => {});
	return { promise, resolve, reject };
};

test('an unavailable related view remains visible without discarding fallback rows or blocking later pages', async () => {
	const model = create(
		async () => [source],
		async () => ({
			source,
			rows: [row('one')],
			nextOffset: 20,
			viewUnavailable: 'Related view unavailable; showing all live links.'
		})
	);
	await model.refresh();
	await model.load(get(model).groups[0].key);
	expect(get(model).groups[0]).toMatchObject({
		rows: [row('one')],
		nextOffset: 20,
		loaded: true,
		error: '',
		viewUnavailable: 'Related view unavailable; showing all live links.'
	});
});

test('discovery loads only metadata until a relationship group is opened', async () => {
	const reads: number[] = [];
	const model = create(
		async () => [source],
		async (s, offset) => {
			reads.push(offset);
			return { source: s, rows: [row('one')], nextOffset: null };
		}
	);
	await model.refresh();
	expect(reads).toEqual([]);
	const group = get(model).groups[0];
	expect(group).toMatchObject({ source, rows: [], loaded: false });
	await model.load(group.key);
	await model.load(group.key);
	expect(reads).toEqual([0]);
	expect(get(model).groups[0]).toMatchObject({ rows: [row('one')], loaded: true });
});

test('pages follow the core offset and replace repeated row IDs', async () => {
	const reads: number[] = [];
	const model = create(
		async () => [source],
		async (s, offset) => {
			reads.push(offset);
			return {
				source: { ...s, incomplete: true },
				rows: offset ? [row('one', 'Changed'), row('two')] : [row('one')],
				nextOffset: offset ? null : 20
			};
		}
	);
	await model.refresh();
	const key = get(model).groups[0].key;
	await model.load(key);
	await model.load(key, true);
	await model.load(key, true);
	expect(reads).toEqual([0, 20]);
	expect(get(model).groups[0]).toMatchObject({
		rows: [row('one', 'Changed'), row('two')],
		source: { incomplete: true },
		nextOffset: null
	});
});

test('a failed later page keeps rows and offset until an explicit retry', async () => {
	let fails = true;
	const model = create(
		async () => [source],
		async (s, offset) => {
			if (offset && fails) {
				fails = false;
				throw Error('Table changed');
			}
			return { source: s, rows: [row(offset ? 'two' : 'one')], nextOffset: offset ? null : 20 };
		}
	);
	await model.refresh();
	const key = get(model).groups[0].key;
	await model.load(key);
	await model.load(key, true);
	expect(get(model).groups[0]).toMatchObject({
		rows: [row('one')],
		nextOffset: 20,
		error: 'Table changed',
		loading: false
	});
	await model.load(key, true);
	expect(get(model).groups[0]).toMatchObject({ rows: [row('one'), row('two')], error: '' });
});

test('failure in one source does not hide a different column or its results', async () => {
	const other = { ...source, column: 'related', type: 'multi_ref' as const };
	const model = create(
		async () => [source, other],
		async (s) => {
			if (s.column === source.column) throw Error('Unavailable');
			return { source: s, rows: [row('two')], nextOffset: null };
		}
	);
	await model.refresh();
	const [a, b] = get(model).groups;
	expect(a.key).not.toBe(b.key);
	await model.load(a.key);
	await model.load(b.key);
	expect(get(model).groups.map((g) => [g.error, g.rows.length])).toEqual([
		['Unavailable', 0],
		['', 1]
	]);
});

test('refresh ignores old metadata successes and failures', async () => {
	for (const fails of [false, true]) {
		const held = deferred<ReferenceSource[]>();
		let calls = 0;
		const model = create(
			() => (++calls === 1 ? held.promise : Promise.resolve([])),
			async () => {
				throw Error('No row reads');
			}
		);
		const pending = model.refresh();
		await model.refresh();
		if (fails) held.reject(Error('Old'));
		else held.resolve([source]);
		await pending;
		expect(get(model)).toMatchObject({ groups: [], loading: false, error: '' });
	}
});

test('refresh and disposal ignore old pages without mutating the current list', async () => {
	for (const dispose of [false, true])
		for (const fails of [false, true]) {
			const held = deferred<ReferencedByPage>();
			const model = create(
				async () => [source],
				() => held.promise
			);
			await model.refresh();
			const key = get(model).groups[0].key;
			const pending = model.load(key);
			if (dispose) model.dispose();
			else await model.refresh();
			const before = get(model);
			if (fails) held.reject(Error('Old'));
			else held.resolve({ source, rows: [row('old')], nextOffset: 20 });
			await pending;
			expect(get(model)).toEqual(before);
			if (dispose) {
				await model.refresh();
				await model.load(key);
				expect(get(model)).toEqual(before);
			}
		}
});

test('pending group reads cannot duplicate a page request', async () => {
	const held = deferred<ReferencedByPage>();
	let calls = 0;
	const model = create(
		async () => [source],
		() => {
			calls++;
			return held.promise;
		}
	);
	await model.refresh();
	const key = get(model).groups[0].key;
	const pending = model.load(key);
	const duplicate = model.load(key),
		extra = model.load(key, true);
	try {
		expect(calls).toBe(1);
	} finally {
		held.resolve({ source, rows: [], nextOffset: null });
	}
	await Promise.all([pending, duplicate, extra]);
});

test('metadata failure stays visible and supports a manual refresh', async () => {
	let fails = true;
	const model = create(
		async () => {
			if (fails) {
				fails = false;
				throw Error('Catalog unavailable');
			}
			return [source];
		},
		async (s) => ({ source: s, rows: [], nextOffset: null })
	);
	await model.refresh();
	expect(get(model)).toMatchObject({ groups: [], error: 'Catalog unavailable', loading: false });
	await model.refresh();
	expect(get(model).error).toBe('');
	expect(get(model).groups).toHaveLength(1);
});

test('reload refreshes opened groups in place without collapsing the list', async () => {
	let rows = [row('one')];
	const model = create(
		async () => [source, { ...source, column: 'reviewer', label: 'Reviewer' }],
		async (target) => ({ source: target, rows, nextOffset: null })
	);
	await model.refresh();
	const [opened, closed] = get(model).groups;
	await model.load(opened.key);
	rows = [row('one'), row('two')];
	await model.reload();
	const state = get(model);
	expect(state.loading).toBe(false);
	expect(state.groups.map((g) => [g.loaded, g.rows.map((r) => r.record.id)])).toEqual([
		[true, ['one', 'two']],
		[false, []]
	]);
	expect(state.groups[1].key).toBe(closed.key);
});
