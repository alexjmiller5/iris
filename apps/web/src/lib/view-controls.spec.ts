import { expect, test } from 'vitest';
import { editSort, parseFilter, queryDefinition } from './view-controls';

test('changing the first sort retains the second and its option mode', () => {
	const initial = [
		{ column: 'status', direction: 'desc' as const, mode: 'options' as const },
		{ column: 'tags', direction: 'asc' as const, mode: 'options' as const }
	];
	expect(editSort(initial, 0, { direction: 'asc' })).toEqual([
		{ ...initial[0], direction: 'asc' },
		initial[1]
	]);
	expect(initial[0].direction).toBe('desc');
});
test('Today, empty and numeric filters keep distinct typed meanings', () => {
	expect(parseFilter('due', 'lte', '', 'date', true)).toEqual({
		column: 'due',
		op: 'lte',
		relative: 'today'
	});
	expect(parseFilter('due', 'empty', '', 'date', true)).toEqual({ column: 'due', op: 'empty' });
	expect(parseFilter('n', 'gte', '0', 'int', false)).toEqual({ column: 'n', op: 'gte', value: 0 });
	expect(() => parseFilter('n', 'gte', '', 'int', false)).toThrow('number');
	expect(() => parseFilter('n', 'gte', '0', 'int', true)).toThrow();
});
test('runtime query keeps grouped conditions and resolves Today without serializing its clock', () => {
	const definition = {
		version: 2,
		timeZone: 'America/New_York',
		groups: [
			{
				match: 'any' as const,
				filters: [{ column: 'due', op: 'lte' as const, relative: 'today' as const }]
			}
		],
		actions: [{ id: 'review', label: 'Review', values: { status: 'Done' } }],
		layout: [{ kind: 'action' as const, id: 'review' }]
	};
	const view = queryDefinition('items', definition, new Date('2026-03-08T16:00:00Z'));
	expect(view.calendar?.end).toBe('2026-03-09T04:00:00.000Z');
	expect(view.groups).toEqual(definition.groups);
	expect(view).not.toHaveProperty('actions');
	expect(definition).not.toHaveProperty('calendar');
});
