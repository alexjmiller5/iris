import { expect, test } from 'vitest';
import { get } from 'svelte/store';
import type { RejectedEdit, RejectionsPage } from 'iris-core/client';
import { createRejectionInbox, rejectionSnapshot } from './rejection-inbox';

const entry = (rowID: string, table = 'items'): RejectedEdit => ({
	table,
	rowID,
	submitted: { id: rowID },
	errors: [{ id: rowID, message: 'Required' }]
});
const deferred = <T>() => {
	let resolve!: (value: T) => void, reject!: (error: Error) => void;
	const promise = new Promise<T>((yes, no) => {
		resolve = yes;
		reject = no;
	});
	return { promise, resolve, reject };
};

test('snapshot preserves the core page and reports first-page failure separately', async () => {
	const page = { rejections: [entry('a')], nextOffset: 100 };
	expect(await rejectionSnapshot(async () => page)).toEqual({ page, error: '' });
	expect(await rejectionSnapshot(() => page)).toEqual({ page, error: '' });
	expect(
		await rejectionSnapshot(async () => {
			throw Error('Invalid stored rejection data.');
		})
	).toEqual({ page: null, error: 'Invalid stored rejection data.' });
});

test('known total stays distinct from loaded count and pages stop at the core terminal', async () => {
	const calls: number[] = [];
	const model = createRejectionInbox(async (offset) => {
		calls.push(offset);
		return { rejections: [entry(String(offset))], nextOffset: offset === 100 ? 200 : null };
	});
	model.reset(205, { page: { rejections: [entry('first')], nextOffset: 100 }, error: '' });
	expect(get(model)).toMatchObject({ total: 205, entries: [entry('first')], nextOffset: 100 });
	await model.more();
	await model.more();
	await model.more();
	expect(calls).toEqual([100, 200]);
	expect(get(model)).toMatchObject({
		total: 205,
		entries: [entry('first'), entry('100'), entry('200')],
		nextOffset: null
	});
});

test('failure retains loaded entries and the exact offset for explicit retry', async () => {
	let fail = true;
	const calls: number[] = [];
	const model = createRejectionInbox(async (offset) => {
		calls.push(offset);
		if (fail) throw Error('Read failed');
		return { rejections: [entry('b')], nextOffset: null };
	});
	model.reset(101, { page: { rejections: [entry('a')], nextOffset: 100 }, error: '' });
	await model.more();
	expect(get(model)).toMatchObject({
		entries: [entry('a')],
		nextOffset: 100,
		error: 'Read failed',
		loading: false
	});
	expect(calls).toEqual([100]);
	fail = false;
	await model.more();
	expect(calls).toEqual([100, 100]);
	expect(get(model)).toMatchObject({
		entries: [entry('a'), entry('b')],
		nextOffset: null,
		error: ''
	});
});

test('corrupt first page keeps the total and retries at zero', async () => {
	const calls: number[] = [];
	const model = createRejectionInbox(async (offset) => {
		calls.push(offset);
		return { rejections: [entry('a')], nextOffset: null };
	});
	model.reset(1, { page: null, error: 'Invalid stored rejection data.' });
	expect(get(model)).toMatchObject({
		total: 1,
		entries: [],
		error: 'Invalid stored rejection data.'
	});
	await model.more();
	expect(calls).toEqual([0]);
	expect(get(model).entries).toEqual([entry('a')]);
});

test('dedupe preserves byte identities and table scope, while retaining the core offset', async () => {
	const changed = { ...entry('é'), errors: [{ id: 'é', rule: 'new' }] };
	const model = createRejectionInbox(async () => ({
		rejections: [changed, entry('e\u0301'), entry('é', 'other')],
		nextOffset: 200
	}));
	model.reset(4, { page: { rejections: [entry('é')], nextOffset: 100 }, error: '' });
	await model.more();
	expect(get(model).entries).toEqual([changed, entry('e\u0301'), entry('é', 'other')]);
	expect(get(model).nextOffset).toBe(200);
});

for (const outcome of ['success', 'failure'] as const)
	test(`a new snapshot invalidates an old ${outcome} response`, async () => {
		const pending = deferred<RejectionsPage>();
		const model = createRejectionInbox(() => pending.promise);
		model.reset(2, { page: { rejections: [entry('old')], nextOffset: 100 }, error: '' });
		const request = model.more();
		model.reset(1, { page: { rejections: [entry('new')], nextOffset: null }, error: '' });
		if (outcome === 'success') pending.resolve({ rejections: [entry('stale')], nextOffset: 200 });
		else pending.reject(Error('Stale failure'));
		await request;
		expect(get(model)).toMatchObject({
			total: 1,
			entries: [entry('new')],
			nextOffset: null,
			loading: false,
			error: ''
		});
	});

test('dispose and concurrent load clicks cannot publish or duplicate late reads', async () => {
	const pending = deferred<RejectionsPage>();
	let calls = 0;
	const model = createRejectionInbox(() => {
		calls++;
		return pending.promise;
	});
	model.reset(2, { page: { rejections: [entry('a')], nextOffset: 100 }, error: '' });
	const request = model.more();
	await model.more();
	expect(calls).toBe(1);
	model.dispose();
	pending.resolve({ rejections: [entry('late')], nextOffset: null });
	await request;
	await model.more();
	expect(get(model).entries).toEqual([entry('a')]);
	expect(calls).toBe(1);
});

test('a disposed inbox cannot be revived by a later snapshot', async () => {
	let calls = 0;
	const model = createRejectionInbox(async () => {
		calls++;
		return { rejections: [entry('late')], nextOffset: null };
	});
	model.dispose();
	model.reset(1, { page: null, error: 'A late failure' });
	await model.more();
	expect(calls).toBe(0);
	expect(get(model)).toMatchObject({ total: 0, entries: [], error: '' });
});
