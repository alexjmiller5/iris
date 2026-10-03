import { describe, expect, it } from 'vitest';
import { destinationURL, readDestination, resolveDestination } from './workspace-navigation';

describe('workspace destinations', () => {
	it('round trips opaque identifiers without copying connection or record data', () => {
		const url = destinationURL(
			new URL('https://example.test/workspace?token=private&search=personal#secret'),
			{
				table: 'odd table',
				view: 'view/+?#%',
				row: 'row & café/#'
			}
		);
		expect(url.href).toBe(
			'https://example.test/workspace?table=odd+table&view=view%2F%2B%3F%23%25&row=row+%26+caf%C3%A9%2F%23'
		);
		expect(readDestination(url)).toEqual({
			table: 'odd table',
			view: 'view/+?#%',
			row: 'row & café/#'
		});
	});
	it('rejects ambiguous or incomplete destinations rather than opening a different record', () => {
		for (const query of ['table=a&table=b', 'table=', 'row=one', 'view=one', 'table=a&row=']) {
			expect(() => readDestination(new URL(`https://example.test/workspace?${query}`))).toThrow();
		}
		expect(readDestination(new URL('https://example.test/workspace'))).toEqual({
			table: null,
			view: null,
			row: null
		});
	});
	it('resolves the selected workspace catalog and current saved revision before a full row', async () => {
		const requests: unknown[] = [];
		const saved = {
			id: 'view-1',
			tbl: 'things',
			name: 'Renamed',
			updated_at: 'new',
			definition: { version: 1, columns: ['name'] },
			view: { table: 'things' }
		};
		const workspace = {
			request: async (method: string, args?: unknown) => {
				requests.push([method, args]);
				if (method === 'snapshot')
					return { catalog: { tables: [{ id: 'things' }], properties: [], rules: [] } };
				if (method === 'listViews') return { views: [saved], unavailable: null };
				return [{ id: 'record-1', name: 'Fresh', hidden: 42 }];
			}
		};
		const result = await resolveDestination(
			workspace as never,
			{ table: 'things', view: 'view-1', row: 'record-1' },
			'elsewhere'
		);
		expect(result.view).toBe(saved);
		expect(result.row).toEqual({ id: 'record-1', name: 'Fresh', hidden: 42 });
		expect(requests).toEqual([
			['snapshot', undefined],
			['listViews', { table: 'things' }],
			[
				'rows',
				{
					view: {
						table: 'things',
						filters: [{ column: 'id', op: 'eq', value: 'record-1' }],
						limit: 1,
						trash: false
					}
				}
			]
		]);
	});
	it('does not silently choose a fallback for absent tables or unavailable views', async () => {
		const workspace = {
			request: async (method: string) =>
				method === 'snapshot'
					? { catalog: { tables: [{ id: 'things' }], properties: [], rules: [] } }
					: {
							views: [{ id: 'view-1', tbl: 'things', unavailable: 'Unsupported version' }],
							unavailable: null
						}
		};
		await expect(
			resolveDestination(workspace as never, { table: 'missing', view: null, row: null }, 'things')
		).rejects.toThrow('table');
		await expect(
			resolveDestination(
				workspace as never,
				{ table: 'things', view: 'view-1', row: null },
				'things'
			)
		).rejects.toThrow('Unsupported version');
	});
	it('reports a missing record instead of substituting a cached or unrelated row', async () => {
		const workspace = {
			request: async (method: string) =>
				method === 'snapshot'
					? { catalog: { tables: [{ id: 'things' }], properties: [], rules: [] } }
					: []
		};
		await expect(
			resolveDestination(
				workspace as never,
				{ table: 'things', view: null, row: 'missing' },
				'things'
			)
		).rejects.toThrow('record');
	});
	it('can reopen an explicitly linked trashed record without changing its identity', async () => {
		const reads: boolean[] = [];
		const workspace = {
			request: async (method: string, args?: { view: { trash: boolean } }) => {
				if (method === 'snapshot')
					return { catalog: { tables: [{ id: 'things' }], properties: [], rules: [] } };
				reads.push(args!.view.trash);
				return args!.view.trash ? [{ id: 'trashed', deleted_at: '2026-01-01', hidden: 42 }] : [];
			}
		};
		const result = await resolveDestination(
			workspace as never,
			{ table: 'things', view: null, row: 'trashed' },
			'things'
		);
		expect(result.row).toEqual({ id: 'trashed', deleted_at: '2026-01-01', hidden: 42 });
		expect(reads).toEqual([false, true]);
	});
});
