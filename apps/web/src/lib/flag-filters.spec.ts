import { describe, expect, it } from 'vitest';
import type { Filter, Property } from 'life-ui-core/client';
import { flagFilters, flagOn, toggleFlag } from './flag-filters';

const flag: Property = {
	tbl: 'items',
	col: 'flagged',
	type: 'bool',
	description: 'Needs a look; the reason is in flag_note, not in status.'
};
const properties: Property[] = [
	{ tbl: 'items', col: 'title', type: 'text' },
	{ tbl: 'items', col: 'status', type: 'select' },
	{ tbl: 'items', col: 'flag_note', type: 'text' },
	flag
];

describe('flag quick filters', () => {
	it('pairs a Boolean with the one sibling text column its description names', () => {
		expect(flagFilters(properties)).toEqual([{ flag, reason: properties[2] }]);
	});

	it('offers nothing without exactly one named text sibling', () => {
		const bare = { ...flag, description: 'Needs a look.' };
		const both = { ...flag, description: 'See flag_note or title.' };
		const selectOnly = { ...flag, description: 'Explained by status.' };
		const other = { ...flag, description: 'Reason in flag_note.', tbl: 'other' };
		for (const p of [bare, both, selectOnly, other])
			expect(flagFilters([...properties.slice(0, 3), p])).toEqual([]);
		expect(flagFilters([{ ...properties[2], description: 'Mentions flagged.' }])).toEqual([]);
	});

	it('adds and removes only its own true filter', () => {
		const filters: Filter[] = [{ column: 'status', op: 'eq', value: 'Open' }];
		const on = toggleFlag(filters, 'flagged');
		expect(on).toEqual([...filters, { column: 'flagged', op: 'eq', value: true }]);
		expect(flagOn(on, 'flagged')).toBe(true);
		expect(flagOn([{ column: 'flagged', op: 'eq', value: false }], 'flagged')).toBe(false);
		expect(toggleFlag(on, 'flagged')).toEqual(filters);
		expect(filters).toHaveLength(1);
	});
});
