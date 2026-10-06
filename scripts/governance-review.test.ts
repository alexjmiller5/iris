import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
import { expect, test } from 'bun:test';
const { get } = await import(webDependency('svelte/store')) as typeof import('svelte/store');
import type * as HistoryReview from '../apps/web/src/lib/governance/history-review';
const { createHistoryReview } = await import(
  process.env.LIFE_UI_TEST_HISTORY_REVIEW ?? '../apps/web/src/lib/governance/history-review'
) as typeof HistoryReview;

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test('selection sends exact history IDs to the core preview without deriving an inverse', async () => {
  const calls: string[][] = [];
  const corePreview = Object.freeze({ token: 'opaque-preview', changes: [{ column: 'status', before: 'closed', after: 'open' }] });
  const model = createHistoryReview(async ids => { calls.push(ids); return corePreview; });
  model.select('e\u0301', true);
  model.select('é', true);
  model.select('é', true);
  await model.review();
  expect(calls).toEqual([['e\u0301', 'é']]);
  expect(get(model).preview).toBe(corePreview);
  expect(get(model).error).toBe('');
});

test('changing selected events invalidates the preview and ignores its late reply', async () => {
  const pending = deferred<{ token: string }>();
  const model = createHistoryReview(() => pending.promise);
  model.select('old', true);
  const review = model.review();
  model.select('new', true);
  pending.resolve({ token: 'stale' });
  await review;
  expect(get(model)).toMatchObject({ selected: ['old', 'new'], preview: null, loading: false, error: '' });
});

test('a new workspace or target clears selection and ignores late errors', async () => {
  const pending = deferred<never>();
  const model = createHistoryReview(() => pending.promise);
  model.select('from-previous-target', true);
  const review = model.review();
  model.reset();
  pending.reject(new Error('old workspace conflict'));
  await review;
  expect(get(model)).toEqual({ selected: [], preview: null, loading: false, error: '' });
});

test('core conflict stays visible without producing a usable preview or losing selection', async () => {
  const model = createHistoryReview(async () => { throw new Error('Selected field has changed'); });
  model.select('event-1', true);
  await model.review();
  expect(get(model)).toMatchObject({ selected: ['event-1'], preview: null, loading: false, error: 'Selected field has changed' });
});

test('an empty selection and a disposed panel never request previews', async () => {
  let calls = 0;
  const model = createHistoryReview(async () => { calls++; return {}; });
  await model.review();
  model.select('event-1', true);
  model.dispose();
  await model.review();
  expect(calls).toBe(0);
});

test('retry replaces the failed result but repeated clicks do not duplicate a pending preview', async () => {
  const pending = deferred<{ token: string }>();
  let calls = 0;
  const model = createHistoryReview(async () => { if (++calls === 1) throw new Error('Offline'); return pending.promise; });
  model.select('event-1', true);
  await model.review();
  const retry = model.review();
  await model.review();
  pending.resolve({ token: 'fresh' });
  await retry;
  expect(calls).toBe(2);
  expect(get(model)).toMatchObject({ preview: { token: 'fresh' }, error: '', loading: false });
});
