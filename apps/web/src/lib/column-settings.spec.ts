import { describe, expect, it } from 'vitest';
import type { Property } from 'life-ui-core/client';
import { visibleColumns, toggleColumn, moveColumn, changeWidth } from './column-settings';

const properties: Property[] = [
	{ col: 'status', label: 'Status', type: 'select' },
	{ col: 'notes', label: 'Notes', type: 'markdown' },
	{ col: 'due', label: 'Due', type: 'date' }
];

describe('column selection', () => {
	it('honors explicit empty selection and includes Markdown when selected', () => {
		expect(visibleColumns(properties, [])).toEqual([]);
		expect(visibleColumns(properties, ['notes', 'status'])).toEqual(['notes', 'status']);
	});

	it('omits removed properties and duplicate selections without changing the caller', () => {
		const columns = Object.freeze(['due', 'removed', 'status', 'due']);
		expect(visibleColumns(properties, columns)).toEqual(['due', 'status']);
		expect(columns).toEqual(['due', 'removed', 'status', 'due']);
	});

	it('hides a column and appends it when shown again', () => {
		const columns = Object.freeze(['status', 'due']);
		const hidden = toggleColumn(columns, 'status', false);
		expect(hidden).toEqual(['due']);
		expect(toggleColumn(hidden, 'status', true)).toEqual(['due', 'status']);
		expect(columns).toEqual(['status', 'due']);
	});

	it('does not duplicate a column when shown twice', () => {
		expect(toggleColumn(['status', 'due'], 'status', true)).toEqual(['status', 'due']);
	});

	it('moves a column one position in either direction without changing the caller', () => {
		const columns = Object.freeze(['status', 'notes', 'due']);
		expect(moveColumn(columns, 'notes', -1)).toEqual(['notes', 'status', 'due']);
		expect(moveColumn(columns, 'notes', 1)).toEqual(['status', 'due', 'notes']);
		expect(columns).toEqual(['status', 'notes', 'due']);
	});

	it('keeps the first and last columns within bounds and ignores an absent column', () => {
		const columns = ['status', 'notes', 'due'];
		expect(moveColumn(columns, 'status', -1)).toEqual(columns);
		expect(moveColumn(columns, 'due', 1)).toEqual(columns);
		expect(moveColumn(columns, 'removed', 1)).toEqual(columns);
		expect(moveColumn([], 'status', 1)).toEqual([]);
	});
});

describe('column widths', () => {
	it.each([
		['95', 96],
		['0', 96],
		['-100', 96],
		['801', 800],
		['200.6', 201],
		[' 240 ', 240]
	])('clamps and rounds %s to %i logical pixels', (value, expected) => {
		expect(changeWidth({ notes: 300 }, 'status', value)).toEqual({
			notes: 300,
			status: expected
		});
	});

	it('clears only the chosen width to auto and preserves hidden or removed widths', () => {
		const widths = Object.freeze({ status: 160, notes: 300, removed: 240 });
		expect(changeWidth(widths, 'status', '')).toEqual({ notes: 300, removed: 240 });
		expect(changeWidth(widths, 'status', '   ')).toEqual({ notes: 300, removed: 240 });
		expect(widths).toEqual({ status: 160, notes: 300, removed: 240 });
	});

	it.each(['NaN', 'Infinity', '-Infinity', '1e999', 'no width', '200px'])(
		'rejects invalid width %s without overwriting remembered widths',
		(value) => {
			const widths = Object.freeze({ status: 160, notes: 300 });
			expect(changeWidth(widths, 'status', value)).toBeNull();
			expect(widths).toEqual({ status: 160, notes: 300 });
		}
	);
});
