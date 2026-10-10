import { describe, expect, it } from 'vitest';
import type { Property } from 'iris-core/client';
import { newOptionColor, optionColor, selectValues } from './option-colors';

const status: Property = {
	col: 'status',
	type: 'select',
	options: [{ v: 'To Do', color: 'red' }, { v: 'Done' }, { v: 'Odd', color: 'teal' as never }]
};
const tags: Property = {
	col: 'tags',
	type: 'multi_select',
	options: [{ v: 'Chore', color: 'purple' }]
};

describe('option colors', () => {
	it('reads palette colors only', () => {
		expect(optionColor(status, 'To Do')).toBe('red');
		expect(optionColor(status, 'Done')).toBeNull();
		expect(optionColor(status, 'Odd')).toBeNull();
		expect(optionColor(status, 'Missing')).toBeNull();
	});
	it('lists select and multi-select values', () => {
		expect(selectValues(status, 'To Do')).toEqual(['To Do']);
		expect(selectValues(status, '')).toEqual([]);
		expect(selectValues(status, null)).toEqual([]);
		expect(selectValues(tags, '["Chore","Other"]')).toEqual(['Chore', 'Other']);
		expect(selectValues(tags, 'not json')).toEqual([]);
		expect(selectValues({ type: 'text' }, 'To Do')).toEqual([]);
	});
	it('gives new options the next palette color, never default', () => {
		expect(newOptionColor(0)).toBe('gray');
		expect(newOptionColor(1)).toBe('brown');
		expect(newOptionColor(8)).toBe('red');
		expect(newOptionColor(9)).toBe('gray');
	});
});
