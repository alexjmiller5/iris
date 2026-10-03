import { expect, test } from 'vitest';
import type { WorkspaceDatabase } from './database';
import { prepareDuplicate } from './record-duplicate';
function fixture(replies: Record<string, unknown>, after = (_method: string) => {}) {
	const calls: { method: string; args: unknown }[] = [];
	const workspace = {
		async request(method: string, args?: unknown) {
			calls.push({ method, args });
			after(method);
			const value = replies[method];
			if (value instanceof Error) throw value;
			return value;
		}
	} as Pick<WorkspaceDatabase, 'request'>;
	return { workspace, calls };
}
const catalog = {
	tables: [{ id: 'items' }],
	properties: [{ tbl: 'items', col: 'title' }],
	rules: []
};
const replies = {
	snapshot: { catalog },
	writeability: { writable: true, reason: null },
	rows: [{ id: 'A', title: 'Saved', hidden: 'Full', updated_at: 'revision' }]
};
test('duplicate preparation reads fresh catalog, permission and a full row without writes', async () => {
	const { workspace, calls } = fixture(replies);
	expect(await prepareDuplicate(workspace, 'items', 'A', () => true)).toEqual({
		catalog,
		permission: replies.writeability,
		row: replies.rows[0]
	});
	expect(calls).toEqual([
		{ method: 'snapshot', args: undefined },
		{ method: 'writeability', args: { table: 'items' } },
		{
			method: 'rows',
			args: {
				view: { table: 'items', filters: [{ column: 'id', op: 'eq', value: 'A' }], limit: 1 }
			}
		}
	]);
});
test.each(['snapshot', 'writeability', 'rows'])(
	'superseded %s reply cannot publish or continue',
	async (method) => {
		let current = true;
		const { workspace, calls } = fixture(replies, (m) => {
			if (m === method) current = false;
		});
		expect(await prepareDuplicate(workspace, 'items', 'A', () => current)).toBeNull();
		expect(calls.at(-1)?.method).toBe(method);
	}
);
test.each([{ rows: [] }, { rows: [{ id: 'a' }] }, { rows: [{ id: 'A', deleted_at: 'trash' }] }])(
	'absent, collation-alias and tombstone sources are unavailable',
	async ({ rows }) => {
		const { workspace } = fixture({ ...replies, rows });
		await expect(prepareDuplicate(workspace, 'items', 'A', () => true)).rejects.toThrow(
			'no longer available'
		);
	}
);
test('denied permission stops before the source is read', async () => {
	const { workspace, calls } = fixture({
		...replies,
		writeability: { writable: false, reason: { message: 'Read-only now' } }
	});
	await expect(prepareDuplicate(workspace, 'items', 'A', () => true)).rejects.toThrow(
		'Read-only now'
	);
	expect(calls).toHaveLength(2);
});
