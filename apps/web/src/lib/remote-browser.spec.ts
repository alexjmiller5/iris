import { expect, test } from 'vitest';
import { get } from 'svelte/store';
import { createRemoteBrowser } from './remote-browser';
import type { RemoteRecord, RemoteRowsPage } from 'iris-core/client';

const row = (id: string, label = id): RemoteRecord => ({
	record: { id, title: label },
	label,
	deleted: false
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

test('online pages replace repeated IDs while advancing the server cursor', async () => {
	const requested: (string | undefined)[] = [];
	const model = createRemoteBrowser(
		async (cursor) => {
			requested.push(cursor);
			return cursor === undefined
				? { rows: [row('a'), row('b')], nextCursor: 'second' }
				: cursor === 'second'
					? { rows: [row('b', 'Changed'), row('c')], nextCursor: 'last' }
					: { rows: [], nextCursor: null };
		},
		async (id) => ({ row: row(id) })
	);
	await model.refresh();
	await model.more();
	expect(get(model).rows.map((r) => r.label)).toEqual(['a', 'Changed', 'c']);
	await model.more();
	await model.more();
	expect(requested).toEqual([undefined, 'second', 'last']);
	expect(get(model).nextCursor).toBeNull();
});

test('a failed later page retains its records and cursor for an explicit retry', async () => {
	let attempts = 0;
	const model = createRemoteBrowser(
		async (cursor) => {
			if (!cursor) return { rows: [row('a')], nextCursor: 'next' };
			if (++attempts === 1) throw Error('429 capped');
			return { rows: [row('b')], nextCursor: null };
		},
		async () => ({ row: null })
	);
	await model.refresh();
	await model.more();
	expect(get(model)).toMatchObject({
		rows: [row('a')],
		nextCursor: 'next',
		error: '429 capped',
		loading: false
	});
	expect(attempts).toBe(1);
	await model.more();
	expect(get(model).rows).toEqual([row('a'), row('b')]);
});

test('refresh resets both paging and selection before its receipt arrives', async () => {
	const held = deferred<RemoteRowsPage>();
	let calls = 0;
	const model = createRemoteBrowser(
		async () => (++calls === 1 ? { rows: [row('a')], nextCursor: 'next' } : held.promise),
		async (id) => ({ row: row(id) })
	);
	await model.refresh();
	await model.open('a');
	const pending = model.refresh();
	expect(get(model)).toMatchObject({ rows: [], selected: null, nextCursor: null, loading: true });
	held.resolve({ rows: [row('new')], nextCursor: null });
	await pending;
	expect(get(model).rows).toEqual([row('new')]);
});

test('opening rereads an ID and missing records preserve the list', async () => {
	const model = createRemoteBrowser(
		async () => ({ rows: [row('a', 'Old')], nextCursor: null }),
		async (id) => ({ row: id === 'a' ? { ...row('a', 'Fresh'), deleted: true } : null })
	);
	await model.refresh();
	await model.open('a');
	expect(get(model).selected).toEqual({ ...row('a', 'Fresh'), deleted: true });
	model.back();
	await model.open('missing');
	expect(get(model)).toMatchObject({
		rows: [row('a', 'Old')],
		selected: null,
		error: expect.stringContaining('not found')
	});
});

test('Back prevents an old record response from replacing a newer selection', async () => {
	const held = deferred<{ row: RemoteRecord | null }>();
	const model = createRemoteBrowser(
		async () => ({ rows: [], nextCursor: null }),
		async (id) => (id === 'a' ? held.promise : { row: row(id) })
	);
	const pending = model.open('a');
	model.back();
	await model.open('b');
	held.resolve({ row: row('a') });
	await pending;
	expect(get(model).selected?.record.id).toBe('b');
});

test('disposal suppresses both late success and late failure', async () => {
	for (const fails of [false, true]) {
		const held = deferred<RemoteRowsPage>();
		const model = createRemoteBrowser(
			() => held.promise,
			async () => ({ row: null })
		);
		const pending = model.refresh();
		expect(get(model).loading).toBe(true);
		model.dispose();
		const previous = get(model);
		if (fails) held.reject(Error('late failure'));
		else held.resolve({ rows: [row('late')], nextCursor: null });
		await pending;
		await model.refresh();
		await model.more();
		await model.open('late');
		expect(get(model)).toEqual(previous);
	}
});

test('a superseding refresh ignores both stale success and stale failure', async () => {
	for (const fails of [false, true]) {
		const held = deferred<RemoteRowsPage>();
		let calls = 0;
		const model = createRemoteBrowser(
			() =>
				++calls === 1
					? held.promise
					: Promise.resolve({ rows: [row('current')], nextCursor: null }),
			async () => ({ row: null })
		);
		const pending = model.refresh();
		await model.refresh();
		if (fails) held.reject(Error('stale'));
		else held.resolve({ rows: [row('stale')], nextCursor: 'stale' });
		await pending;
		expect(get(model)).toMatchObject({
			rows: [row('current')],
			error: '',
			nextCursor: null,
			loading: false
		});
	}
});
