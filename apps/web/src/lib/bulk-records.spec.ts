import { expect, test } from 'vitest';
import type { Row } from 'life-ui-core/client';
import type { WorkspaceDatabase } from './database';
import { runBulkRecords } from './bulk-records';

const revision = '2026-01-02T03:04:05.123Z';
function fixture(records: Row[], write: (patch: Row) => Promise<Row> = async (patch) => patch) {
	const saved: Row[] = [];
	const revisions: unknown[] = [];
	const database = {
		async request(method: string, args: any) {
			if (method === 'writeability') return { writable: true, reason: null };
			if (method === 'rows') return records.filter((row) => row.id === args.view.filters[0].value);
			if (method !== 'write') throw Error('Unexpected operation');
			revisions.push(args.expectedUpdatedAt);
			const result = await write(args.patch);
			saved.push(result);
			return result;
		}
	} as Pick<WorkspaceDatabase, 'request'>;
	return { database, saved, revisions };
}

test('a rejected row does not hide successful receipts or stop later selected rows', async () => {
	const { database, saved, revisions } = fixture(
		['A', 'B', 'C'].map((id) => ({ id, updated_at: revision })),
		async (patch) => {
			if (patch.id === 'B') throw Error('Rule rejected this row');
			return { ...patch, updated_at: '2026-01-02T04:00:00.000Z' };
		}
	);
	const results = await runBulkRecords(database, 'items', ['A', 'B', 'C'], { title: '' });
	expect(results.map(({ id, status }) => ({ id, status }))).toEqual([
		{ id: 'A', status: 'succeeded' },
		{ id: 'B', status: 'failed' },
		{ id: 'C', status: 'succeeded' }
	]);
	expect(results[1].error).toBe('Rule rejected this row');
	expect(saved.map((row) => [row.id, row.title])).toEqual([
		['A', ''],
		['C', '']
	]);
	expect(revisions).toEqual([revision, revision, revision]);
});

test('cancellation during a committed write preserves its receipt and leaves later rows unattempted', async () => {
	const controller = new AbortController();
	const { database, saved } = fixture(
		['A', 'B'].map((id) => ({ id, updated_at: revision })),
		async (patch) => {
			controller.abort();
			return patch;
		}
	);
	const results = await runBulkRecords(
		database,
		'items',
		['A', 'B'],
		{ deleted_at: true },
		{ signal: controller.signal }
	);
	expect(results.map((result) => result.status)).toEqual(['succeeded', 'unattempted']);
	expect(saved).toEqual([{ id: 'A', deleted_at: true }]);
});

test('each exact selected identity is retained and inputs are frozen before asynchronous work', async () => {
	const ids = ['é', 'e\u0301'];
	const patch = { title: null };
	const { database, saved } = fixture(
		ids.map((id) => ({ id, updated_at: revision })),
		async (value) => {
			ids.pop();
			return value;
		}
	);
	const results = await runBulkRecords(database, 'items', ids, patch);
	expect(results.map((result) => result.id)).toEqual(['é', 'e\u0301']);
	expect(saved).toEqual([
		{ id: 'é', title: null },
		{ id: 'e\u0301', title: null }
	]);
});

test('missing rows and missing revisions never become unconditional updates', async () => {
	const { database, saved } = fixture([{ id: 'no-revision' }]);
	const results = await runBulkRecords(database, 'items', ['absent', 'no-revision'], {
		title: 'new'
	});
	expect(results.map((result) => result.status)).toEqual(['failed', 'failed']);
	expect(saved).toEqual([]);
});

test('duplicate selections and managed-column patches fail before any operation', async () => {
	const database = {
		request: async () => {
			throw Error('Must not access database');
		}
	} as Pick<WorkspaceDatabase, 'request'>;
	await expect(runBulkRecords(database, 'items', ['A', 'A'], { title: 'x' })).rejects.toThrow(
		/selection/
	);
	await expect(runBulkRecords(database, 'items', ['A'], { id: 'B' })).rejects.toThrow(/managed/);
});

test('a context change during a row read prevents its write and every later read', async () => {
	let current = true;
	const calls: string[] = [];
	const database = {
		async request(method: string) {
			calls.push(method);
			if (method === 'writeability') return { writable: true, reason: null };
			current = false;
			return [{ id: 'A', updated_at: revision }];
		}
	} as Pick<WorkspaceDatabase, 'request'>;
	const results = await runBulkRecords(
		database,
		'items',
		['A', 'B'],
		{ title: 'x' },
		{ isCurrent: () => current }
	);
	expect(results.map((result) => result.status)).toEqual(['unattempted', 'unattempted']);
	expect(calls).toEqual(['writeability', 'rows']);
});
