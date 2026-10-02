import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { get } from 'svelte/store';
import type { SearchHit } from 'life-ui-core/client';
import { createSearchModel } from './search-dialog';

const hit = (id: string): SearchHit => ({
	table: 'notes',
	id,
	label: `Note ${id}`,
	excerpt: 'Plain text'
});
function fixture() {
	const requests: {
		text: string;
		offset: number;
		resolve: (hits: SearchHit[]) => void;
		reject: (error: Error) => void;
	}[] = [];
	const model = createSearchModel(
		(text, offset) =>
			new Promise((resolve, reject) => {
				requests.push({ text, offset, resolve, reject });
			})
	);
	return { model, requests };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

test('only the latest nonblank text is requested after 200ms, with offset zero', async () => {
	const { model, requests } = fixture();
	model.setQuery('   ');
	await vi.advanceTimersByTimeAsync(200);
	expect(requests).toHaveLength(0);
	model.setQuery('first');
	await vi.advanceTimersByTimeAsync(150);
	model.setQuery(' café ');
	await vi.advanceTimersByTimeAsync(199);
	expect(requests).toHaveLength(0);
	await vi.advanceTimersByTimeAsync(1);
	expect(requests.map(({ text, offset }) => ({ text, offset }))).toEqual([
		{ text: 'café', offset: 0 }
	]);
	requests[0].resolve([hit('new')]);
	await vi.runAllTimersAsync();
	expect(get(model)).toMatchObject({
		text: ' café ',
		hits: [hit('new')],
		loading: false,
		searched: true,
		activeIndex: 0
	});
});

test('typing invalidates an old response immediately, before the next debounce fires', async () => {
	const { model, requests } = fixture();
	model.setQuery('old');
	await vi.advanceTimersByTimeAsync(200);
	model.setQuery('new');
	requests[0].resolve([hit('old')]);
	await vi.advanceTimersByTimeAsync(0);
	expect(get(model)).toMatchObject({ hits: [], loading: true, searched: false, error: '' });
	await vi.advanceTimersByTimeAsync(200);
	requests[1].resolve([hit('new')]);
	await vi.runAllTimersAsync();
	expect(get(model).hits).toEqual([hit('new')]);
});

test.each(['resolve', 'reject'] as const)(
	'late old %s cannot replace the latest successful result or status',
	async (settle) => {
		const { model, requests } = fixture();
		model.setQuery('old');
		await vi.advanceTimersByTimeAsync(200);
		model.setQuery('new');
		await vi.advanceTimersByTimeAsync(200);
		requests[1].resolve([hit('new')]);
		await vi.advanceTimersByTimeAsync(0);
		if (settle === 'resolve') requests[0].resolve([hit('old')]);
		else requests[0].reject(new Error('old failure'));
		await vi.runAllTimersAsync();
		expect(get(model)).toMatchObject({ hits: [hit('new')], loading: false, error: '' });
	}
);

test('clearing text cancels its timer and prevents an in-flight response from repopulating results', async () => {
	const { model, requests } = fixture();
	model.setQuery('pending');
	model.setQuery('');
	await vi.advanceTimersByTimeAsync(200);
	expect(requests).toHaveLength(0);
	model.setQuery('running');
	await vi.advanceTimersByTimeAsync(200);
	model.setQuery(' \n ');
	requests[0].resolve([hit('old')]);
	await vi.runAllTimersAsync();
	expect(get(model)).toMatchObject({
		hits: [],
		loading: false,
		searched: false,
		hasMore: false,
		activeIndex: -1
	});
});

test('a failed first page can be retried without changing text', async () => {
	const { model, requests } = fixture();
	model.setQuery('retry');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].reject(new Error('Unavailable'));
	await vi.advanceTimersByTimeAsync(0);
	expect(get(model)).toMatchObject({ loading: false, error: 'Unavailable', hits: [] });
	const retry = model.retry();
	expect(requests[1]).toMatchObject({ text: 'retry', offset: 0 });
	expect(get(model).error).toBe('');
	requests[1].resolve([]);
	await retry;
	expect(get(model)).toMatchObject({
		loading: false,
		error: '',
		searched: true,
		hits: [],
		hasMore: false
	});
});

test.each([0, 49, 51])('a page of %i hits does not advertise or request More', async (count) => {
	const { model, requests } = fixture();
	model.setQuery('short');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve(Array.from({ length: count }, (_, i) => hit(String(i))));
	await vi.runAllTimersAsync();
	await model.more();
	expect(get(model).hasMore).toBe(false);
	expect(requests).toHaveLength(1);
});

test('More appends the next 50-offset page once and preserves the keyboard selection', async () => {
	const { model, requests } = fixture();
	model.setQuery('pages');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve(Array.from({ length: 50 }, (_, i) => hit(String(i))));
	await vi.runAllTimersAsync();
	model.move(1);
	expect(get(model).hasMore).toBe(true);
	const more = model.more();
	await model.more();
	expect(requests.map(({ offset }) => offset)).toEqual([0, 50]);
	requests[1].resolve([hit('last')]);
	await more;
	expect(get(model).hits).toHaveLength(51);
	expect(get(model).hits.at(-1)).toEqual(hit('last'));
	expect(get(model)).toMatchObject({ activeIndex: 1, hasMore: false, loading: false });
});

test('a failed More keeps existing hits and retries the same offset', async () => {
	const { model, requests } = fixture();
	model.setQuery('pages');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve(Array.from({ length: 50 }, (_, i) => hit(String(i))));
	await vi.runAllTimersAsync();
	const more = model.more();
	requests[1].reject(new Error('Try again'));
	await more;
	expect(get(model).hits).toHaveLength(50);
	expect(get(model)).toMatchObject({ error: 'Try again', loading: false, hasMore: true });
	const retry = model.retry();
	expect(requests[2]).toMatchObject({ text: 'pages', offset: 50 });
	requests[2].resolve([]);
	await retry;
	expect(get(model)).toMatchObject({ error: '', hasMore: false });
	expect(get(model).hits).toHaveLength(50);
});

test('changing the query while More runs discards that page and resets the offset', async () => {
	const { model, requests } = fixture();
	model.setQuery('pages');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve(Array.from({ length: 50 }, (_, i) => hit(String(i))));
	await vi.runAllTimersAsync();
	const more = model.more();
	model.setQuery('fresh');
	requests[1].resolve([hit('stale-page')]);
	await more;
	expect(get(model)).toMatchObject({ hits: [], loading: true, hasMore: false });
	await vi.advanceTimersByTimeAsync(200);
	expect(requests[2]).toMatchObject({ text: 'fresh', offset: 0 });
	requests[2].resolve([hit('fresh')]);
	await vi.runAllTimersAsync();
	expect(get(model).hits).toEqual([hit('fresh')]);
});

test('keyboard navigation wraps within current results and resets for a new query', async () => {
	const { model, requests } = fixture();
	model.move(-1);
	expect(get(model).activeIndex).toBe(-1);
	model.setQuery('results');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve([hit('first'), hit('second')]);
	await vi.runAllTimersAsync();
	model.move(-1);
	expect(get(model).hits[get(model).activeIndex]).toEqual(hit('second'));
	model.move(1);
	expect(get(model).hits[get(model).activeIndex]).toEqual(hit('first'));
	model.setQuery('another');
	expect(get(model).activeIndex).toBe(-1);
	model.dispose();
});

test('disposing cancels scheduled searches and ignores in-flight completion', async () => {
	const queued = fixture();
	queued.model.setQuery('queued');
	queued.model.dispose();
	await vi.runAllTimersAsync();
	expect(queued.requests).toHaveLength(0);
	const { model, requests } = fixture();
	model.setQuery('running');
	await vi.advanceTimersByTimeAsync(200);
	model.dispose();
	const atClose = get(model);
	requests[0].reject(new Error('late failure'));
	await vi.runAllTimersAsync();
	model.setQuery('after close');
	await model.retry();
	await model.more();
	expect(get(model)).toEqual(atClose);
	expect(requests).toHaveLength(1);
});

test('pointer selection becomes the keyboard selection without accepting stale indices', async () => {
	const { model, requests } = fixture();
	model.setQuery('results');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve([hit('first'), hit('second')]);
	await vi.runAllTimersAsync();
	model.select(1);
	expect(get(model).hits[get(model).activeIndex]).toEqual(hit('second'));
	model.select(100);
	model.select(-1);
	expect(get(model).hits[get(model).activeIndex]).toEqual(hit('second'));
	model.move(1);
	expect(get(model).hits[get(model).activeIndex]).toEqual(hit('first'));
});

test('overlapping pages deduplicate table/id while advancing and retrying the raw offset', async () => {
	const { model, requests } = fixture();
	model.setQuery('changing index');
	await vi.advanceTimersByTimeAsync(200);
	requests[0].resolve(Array.from({ length: 50 }, (_, i) => hit(String(i))));
	await vi.runAllTimersAsync();
	const secondPage = model.more();
	requests[1].resolve([
		{ ...hit('49'), label: 'Updated label' },
		...Array.from({ length: 49 }, (_, i) => hit(String(i + 50)))
	]);
	await secondPage;
	expect(get(model).hits).toHaveLength(99);
	expect(get(model).hits[49].label).toBe('Updated label');
	expect(get(model).hasMore).toBe(true);
	const thirdPage = model.more();
	expect(requests[2]).toMatchObject({ text: 'changing index', offset: 100 });
	requests[2].reject(new Error('Retry this page'));
	await thirdPage;
	const retry = model.retry();
	expect(requests[3].offset).toBe(100);
	requests[3].resolve([hit('99'), { ...hit('0'), table: 'tasks' }]);
	await retry;
	expect(get(model).hits).toHaveLength(101);
	expect(
		get(model)
			.hits.filter((result) => result.id === '0')
			.map((result) => result.table)
	).toEqual(['notes', 'tasks']);
	expect(get(model).hasMore).toBe(false);
	model.setQuery('new query');
	await vi.advanceTimersByTimeAsync(200);
	expect(requests[4]).toMatchObject({ text: 'new query', offset: 0 });
	model.dispose();
});
