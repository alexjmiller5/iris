import { describe, expect, it } from 'vitest';
import { resolveDerivedRecord } from './resolve-derived';
import type { WorkspaceDatabase } from './database';

const row = { id: 'fixture', title: 'Original', updated_at: '2026-01-01T00:00:00Z' };
const receipt = { ...row, computed: 'Resolved', updated_at: '2026-01-02T00:00:00Z' };
function fixture(options: { fail?: string; wrongRow?: boolean; noRefresh?: boolean } = {}) {
	const calls: { method: string; args: unknown }[] = [];
	const database = {
		async request(method: string, args: unknown) {
			calls.push({ method, args });
			if (options.fail === method) throw new Error('Synthetic ' + method + ' failure');
			if (method === 'resolveDerived') return { derived: 1, failed: [] };
			if (method === 'rows')
				return [options.wrongRow ? { ...receipt, id: 'other' } : options.noRefresh ? row : receipt];
			return {};
		}
	} as unknown as WorkspaceDatabase;
	return { database, calls };
}
const connection = { endpoint: 'https://fixture.invalid', token: 'synthetic' };
const download = { maxRows: 500, tables: {} };
describe('Resolve derived field', () => {
	it('runs checked resolve, normal sync and a full exact-row readback', async () => {
		const { database, calls } = fixture();
		const result = await resolveDerivedRecord(
			database,
			connection,
			'examples',
			row,
			'computed',
			download,
			() => true
		);
		expect(result.record).toEqual(receipt);
		expect(calls.map((x) => x.method)).toEqual(['resolveDerived', 'sync', 'rows']);
		expect(calls[0].args).toEqual({
			...connection,
			table: 'examples',
			id: row.id,
			column: 'computed',
			expectedUpdatedAt: row.updated_at
		});
		expect(calls[1].args).toEqual({ ...connection, ...download });
		expect(calls[2].args).toEqual({
			view: { table: 'examples', filters: [{ column: 'id', op: 'eq', value: row.id }], limit: 1 }
		});
	});
	it.each(['resolveDerived', 'sync', 'rows'])(
		'does not turn %s failure into success',
		async (fail) => {
			const { database } = fixture({ fail });
			await expect(
				resolveDerivedRecord(
					database,
					connection,
					'examples',
					row,
					'computed',
					download,
					() => true
				)
			).rejects.toThrow('Synthetic');
		}
	);
	it.each([{ wrongRow: true }, { noRefresh: true }])(
		'rejects wrong or unrefreshed readback %j',
		async (options) => {
			const { database } = fixture(options);
			await expect(
				resolveDerivedRecord(
					database,
					connection,
					'examples',
					row,
					'computed',
					download,
					() => true
				)
			).rejects.toThrow();
		}
	);
	it('stops when the owning editor changes during the provider call', async () => {
		const { database, calls } = fixture();
		await expect(
			resolveDerivedRecord(
				database,
				connection,
				'examples',
				row,
				'computed',
				download,
				() => calls.length === 0
			)
		).rejects.toThrow('changed');
		expect(calls.map((x) => x.method)).toEqual(['resolveDerived']);
	});
});
