import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
import { expect, test } from 'bun:test';
const { get } = await import(webDependency('svelte/store')) as typeof import('svelte/store');
const { createReviewList } = await import(process.env.LIFE_UI_TEST_REVIEW_LIST || '../apps/web/src/lib/governance/review-list') as typeof import('../apps/web/src/lib/governance/review-list');
import type { ReadResult } from '../apps/web/src/lib/governance/contract';
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(yes => { resolve = yes; }); return { promise, resolve }; };
test('content invalidation removes cached pages and rejects an in-flight page after purge', async () => {
  const late = deferred<ReadResult<{ items: { id: string }[]; nextCursor: string | null }>>(); let calls = 0;
  const list = createReviewList(async () => ++calls === 1 ? { kind: 'success', value: { items: [{ id: 'one' }], nextCursor: 'next' } } : late.promise, () => {});
  await list.more(); expect(get(list).items).toEqual([{ id: 'one' }]);
  const reading = list.more(); list.clear(); late.resolve({ kind: 'success', value: { items: [{ id: 'two' }], nextCursor: null } }); await reading;
  expect(get(list).items).toEqual([]); expect(get(list).busy).toBe(false);
});
test('unavailable page clears prior content and invalidates sibling content through its callback', async () => {
  let calls = 0; let invalidations = 0;
  const list = createReviewList(async () => ++calls === 1 ? { kind: 'success', value: { items: [{ id: 'one' }], nextCursor: 'next' } } : { kind: 'unavailable' }, () => { invalidations++; });
  await list.more(); await list.more(); expect(get(list).items).toEqual([]); expect(invalidations).toBe(1);
});
test('paging keeps exact event identity, deduplicates overlaps and stops at end', async () => {
  const cursors: (string | undefined)[] = [];
  const list = createReviewList(async cursor => { cursors.push(cursor); return { kind: 'success', value: { items: cursor ? [{ id: 'e\u0301' }, { id: '\u00e9' }] : [{ id: 'e\u0301' }], nextCursor: cursor ? null : 'next' } }; }, () => {});
  await list.more(); await list.more(); await list.more(); expect(get(list).items).toHaveLength(2); expect(cursors).toEqual([undefined, 'next']);
});
