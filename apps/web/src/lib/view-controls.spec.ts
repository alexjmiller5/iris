import { expect, test } from 'vitest';
import { editSort, parseDayStart, parseFilter, queryDefinition } from './view-controls';

test('day-start controls preserve midnight, minute precision and reject incomplete input', () => {
	expect(parseDayStart('00:00')).toBe(0);
	expect(parseDayStart('03:00')).toBe(180);
	expect(parseDayStart('23:59')).toBe(1439);
	for (const invalid of ['', '24:00', '03:60', '3:00', '03:00:00'])
		expect(() => parseDayStart(invalid)).toThrow();
});

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

test('the selected view policy changes query bounds without changing saved values', () => {
	const definition = {
		version: 2,
		timeZone: 'America/New_York',
		dayStartMinutes: 180,
		filters: [{ column: 'due', op: 'lte' as const, relative: 'today' as const }]
	};
	const original = JSON.stringify(definition);
	expect(
		queryDefinition('items', definition, new Date('2026-06-02T06:59:59.999Z')).calendar
	).toEqual({
		today: '2026-06-01',
		start: '2026-06-01T07:00:00.000Z',
		end: '2026-06-02T07:00:00.000Z'
	});
	expect(
		queryDefinition('items', definition, new Date('2026-06-02T07:00:00Z')).calendar?.today
	).toBe('2026-06-02');
	expect(JSON.stringify(definition)).toBe(original);
	expect(queryDefinition('items', { ...definition, filters: [] })).not.toHaveProperty('calendar');
});
