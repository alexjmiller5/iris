import { describe, expect, it } from 'vitest';
import type { Property, SearchHit } from 'life-ui-core/client';
import { labelStatus } from './search-status';

const properties: Property[] = [
	{
		tbl: 'items',
		col: 'status',
		type: 'select',
		options: [{ v: 'Retired', d: 'No longer in use.' }, { v: 'Open' }]
	},
	{ tbl: 'other', col: 'status', type: 'text' }
];
const hit = (table: string, id: string): SearchHit => ({ table, id, label: id, excerpt: '' });

describe('search hit status labels', () => {
	it('labels hits with their lifecycle status and its catalog description', async () => {
		const values: Record<string, unknown> = { a: 'Retired', b: 'Open', c: null, d: 'Unknown' };
		const reads: string[] = [];
		const hits = [hit('items', 'a'), hit('items', 'b'), hit('items', 'c'), hit('items', 'd')];
		const labeled = await labelStatus(
			[...hits, hit('other', 'x')],
			properties,
			async (table, id) => (reads.push(`${table}/${id}`), values[id])
		);
		expect(labeled.map((h) => ('status' in h ? h.status : undefined))).toEqual([
			{ v: 'Retired', d: 'No longer in use.' },
			{ v: 'Open', d: undefined },
			undefined,
			{ v: 'Unknown', d: undefined },
			undefined
		]);
		expect(reads).not.toContain('other/x');
	});

	it('keeps a hit unlabeled when its read fails', async () => {
		const [only] = await labelStatus([hit('items', 'a')], properties, async () => {
			throw new Error('gone');
		});
		expect(only).toEqual(hit('items', 'a'));
	});
});
