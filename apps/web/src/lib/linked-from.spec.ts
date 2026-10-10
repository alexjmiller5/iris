import { get } from 'svelte/store';
import { expect, test } from 'vitest';
import { createLinkedFrom } from './linked-from';

const row = (id: string) => ({ table: 'notes', id, label: `Note ${id}` });
function deferred<T>() {
	let resolve!: (value: T) => void, reject!: (error: Error) => void;
	const promise = new Promise<T>((a, b) => ((resolve = a), (reject = b)));
	return { promise, resolve, reject };
}

test('backlinks page forward, deduplicate and refresh from the first page', async () => {
	const pages = [
		{ rows: [row('a'), row('b')], nextOffset: 2, incomplete: false, indexing: true },
		{ rows: [row('b'), row('c')], nextOffset: null, incomplete: true, indexing: false }
	];
	const offsets: number[] = [];
	const model = createLinkedFrom(async (offset) => {
		offsets.push(offset);
		return pages[offset ? 1 : 0];
	});
	await model.load();
	expect(get(model)).toMatchObject({ loaded: true, nextOffset: 2, incomplete: false, indexing: true });
	await model.load(true);
	expect(get(model).rows.map((r) => r.id)).toEqual(['a', 'b', 'c']);
	// The latest page says whether the index is still catching up.
	expect(get(model)).toMatchObject({ nextOffset: null, incomplete: true, indexing: false });
	await model.load();
	expect(get(model).rows.map((r) => r.id)).toEqual(['a', 'b']);
	expect(offsets).toEqual([0, 2, 0]);
});

test('late replies from a superseded or disposed load never replace newer state', async () => {
	const first = deferred<any>(),
		second = deferred<any>();
	const replies = [first.promise, second.promise];
	const model = createLinkedFrom(() => replies.shift()!);
	const older = model.load();
	const newer = model.load();
	second.resolve({ rows: [row('new')], nextOffset: null, incomplete: false });
	await newer;
	first.resolve({ rows: [row('old')], nextOffset: null, incomplete: false });
	await older;
	expect(get(model).rows.map((r) => r.id)).toEqual(['new']);
	const late = deferred<any>();
	const disposed = createLinkedFrom(() => late.promise);
	const pending = disposed.load();
	disposed.dispose();
	late.resolve({ rows: [row('x')], nextOffset: null, incomplete: false });
	await pending;
	expect(get(disposed).rows).toEqual([]);
});

test('a failed page keeps loaded rows and its offset for retry', async () => {
	let fail = false;
	const model = createLinkedFrom(async (offset) => {
		if (fail) throw Error('Index unavailable');
		return { rows: [row(String(offset))], nextOffset: offset + 1, incomplete: false, indexing: false };
	});
	await model.load();
	fail = true;
	await model.load(true);
	expect(get(model)).toMatchObject({ error: 'Index unavailable', nextOffset: 1, loading: false });
	expect(get(model).rows.map((r) => r.id)).toEqual(['0']);
	fail = false;
	await model.load(true);
	expect(get(model).rows.map((r) => r.id)).toEqual(['0', '1']);
	expect(get(model).error).toBe('');
});
