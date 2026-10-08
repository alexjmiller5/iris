import { describe, expect, test } from 'vitest';
import type { FilterGroup } from 'life-ui-core/client';
import {
	chipsOf,
	defaultRule,
	describeRule,
	groupDraft,
	operatorsFor,
	placeGroup,
	placeRule,
	removeChip,
	type FilterState
} from './filter-bar';

const types: Record<string, string> = {
	name: 'text',
	status: 'select',
	tags: 'multi_select',
	done: 'bool',
	due: 'date_or_datetime',
	count: 'int'
};
const typeOf = (column: string) => types[column] ?? 'text';
const empty: FilterState = { filters: [], groups: [] };

describe('operators follow the property type', () => {
	test('mixed dates keep ordered comparisons; option types use membership', () => {
		expect(operatorsFor('date_or_datetime')).toEqual([
			'eq',
			'ne',
			'lt',
			'gt',
			'lte',
			'gte',
			'empty',
			'not_empty'
		]);
		expect(operatorsFor('select')).toEqual(['eq', 'ne', 'empty', 'not_empty']);
		expect(operatorsFor('multi_select')).toEqual(['contains', 'empty', 'not_empty']);
		expect(operatorsFor('text')[0]).toBe('contains');
		expect(operatorsFor('bool')).toEqual(['eq']);
	});
	test('a new checkbox chip filters immediately; a new text chip waits for a value', () => {
		expect(placeRule(empty, null, defaultRule('done', 'bool'), typeOf).state.filters).toEqual([
			{ column: 'done', op: 'eq', value: true }
		]);
		const text = placeRule(empty, null, defaultRule('name', 'text'), typeOf);
		expect(text.state).toEqual(empty);
		expect(text.ref).toBeNull();
	});
});

describe('chips apply edits in place', () => {
	const base: FilterState = {
		filters: [
			{ column: 'name', op: 'contains', value: 'a' },
			{ column: 'count', op: 'gt', value: 1 }
		],
		groups: [{ match: 'all', filters: [{ column: 'due', op: 'lte', relative: 'today' }] }]
	};

	test('adding a completed chip appends it and returns its position', () => {
		const added = placeRule(base, null, { column: 'count', op: 'lte', values: ['9'] }, typeOf);
		expect(added.ref).toEqual({ kind: 'filter', index: 2 });
		expect(added.state.filters[2]).toEqual({ column: 'count', op: 'lte', value: 9 });
		expect(base.filters).toHaveLength(2);
	});

	test('editing keeps the clause position and every other clause', () => {
		const ref = { kind: 'filter' as const, index: 0 };
		const edited = placeRule(base, ref, { column: 'name', op: 'eq', values: ['b'] }, typeOf);
		expect(edited.ref).toEqual(ref);
		expect(edited.state).toEqual({
			filters: [{ column: 'name', op: 'eq', value: 'b' }, base.filters[1]],
			groups: base.groups
		});
	});

	test('clearing a value removes the clause; an invalid number keeps the last valid one', () => {
		const ref = { kind: 'filter' as const, index: 1 };
		const cleared = placeRule(base, ref, { column: 'count', op: 'gt', values: [''] }, typeOf);
		expect(cleared.state.filters).toEqual([base.filters[0]]);
		expect(cleared.ref).toBeNull();
		const invalid = placeRule(base, ref, { column: 'count', op: 'gt', values: ['x'] }, typeOf);
		expect(invalid.state).toBe(base);
		expect(invalid.ref).toEqual(ref);
		expect(invalid.error).toMatch(/number/i);
	});

	test('empty checks and Today need no value', () => {
		expect(
			placeRule(empty, null, { column: 'name', op: 'empty', values: [] }, typeOf).state.filters
		).toEqual([{ column: 'name', op: 'empty' }]);
		expect(
			placeRule(empty, null, { column: 'due', op: 'lt', values: [], relative: 'today' }, typeOf)
				.state.filters
		).toEqual([{ column: 'due', op: 'lt', relative: 'today' }]);
	});

	test('removing a chip removes exactly its clause', () => {
		expect(removeChip(base, { kind: 'group', index: 0 })).toEqual({
			filters: base.filters,
			groups: []
		});
		expect(removeChip(base, { kind: 'filter', index: 0 }).filters).toEqual([base.filters[1]]);
	});
});

describe('several checked options become a group', () => {
	test('is any of / is none of round-trip between a filter and a group', () => {
		const one = placeRule(empty, null, { column: 'status', op: 'eq', values: ['Done'] }, typeOf);
		expect(one.state.filters).toEqual([{ column: 'status', op: 'eq', value: 'Done' }]);
		const two = placeRule(
			one.state,
			one.ref,
			{ column: 'status', op: 'eq', values: ['Done', 'Doing'] },
			typeOf
		);
		expect(two.state).toEqual({
			filters: [],
			groups: [
				{
					match: 'any',
					filters: [
						{ column: 'status', op: 'eq', value: 'Done' },
						{ column: 'status', op: 'eq', value: 'Doing' }
					]
				}
			]
		});
		expect(two.ref).toEqual({ kind: 'group', index: 0 });
		expect(chipsOf(two.state)).toEqual([
			{ ref: two.ref, rule: { column: 'status', op: 'eq', values: ['Done', 'Doing'] } }
		]);
		const none = placeRule(
			two.state,
			two.ref,
			{ column: 'status', op: 'ne', values: ['Done', 'Doing'] },
			typeOf
		);
		expect(none.state.groups[0].match).toBe('all');
		const back = placeRule(
			none.state,
			none.ref,
			{ column: 'status', op: 'ne', values: ['Done'] },
			typeOf
		);
		expect(back.state).toEqual({
			filters: [{ column: 'status', op: 'ne', value: 'Done' }],
			groups: []
		});
		expect(back.ref).toEqual({ kind: 'filter', index: 0 });
	});

	test('mixed or nested groups stay advanced and are never rewritten as chips', () => {
		const mixed: FilterGroup = {
			match: 'any',
			filters: [
				{ column: 'status', op: 'eq', value: 'Done' },
				{ column: 'name', op: 'contains', value: 'x' }
			]
		};
		const allOf: FilterGroup = {
			match: 'all',
			filters: [
				{ column: 'tags', op: 'contains', value: 'a' },
				{ column: 'tags', op: 'contains', value: 'b' }
			]
		};
		expect(chipsOf({ filters: [], groups: [mixed, allOf] }).map((chip) => chip.rule)).toEqual([
			null,
			null
		]);
	});
});

describe('advanced groups', () => {
	const base: FilterState = {
		filters: [{ column: 'name', op: 'contains', value: 'a' }],
		groups: [
			{
				match: 'any',
				filters: [
					{ column: 'count', op: 'gt', value: 3 },
					{ column: 'done', op: 'eq', value: true }
				]
			}
		]
	};
	test('incomplete rules are kept in the editor but never saved', () => {
		const draft = groupDraft(base.groups[0]);
		draft.rules.push({ column: 'name', op: 'contains', values: [] });
		draft.match = 'all';
		const placed = placeGroup(base, { kind: 'group', index: 0 }, draft, typeOf);
		expect(placed.state.groups).toEqual([{ ...base.groups[0], match: 'all' }]);
		expect(placed.state.filters).toEqual(base.filters);
	});
	test('a new group appears only once it has a complete rule; emptying it removes it', () => {
		const draft = { match: 'any' as const, rules: [defaultRule('status', 'select')] };
		const pending = placeGroup(base, null, draft, typeOf);
		expect(pending.ref).toBeNull();
		expect(pending.state).toEqual(base);
		draft.rules[0].values = ['Done'];
		const added = placeGroup(base, null, draft, typeOf);
		expect(added.ref).toEqual({ kind: 'group', index: 1 });
		expect(added.state.groups[1]).toEqual({
			match: 'any',
			filters: [{ column: 'status', op: 'eq', value: 'Done' }]
		});
		const removed = placeGroup(
			added.state,
			added.ref,
			{ match: 'any', rules: [{ ...draft.rules[0], values: [] }] },
			typeOf
		);
		expect(removed.state).toEqual(base);
		expect(removed.ref).toBeNull();
	});
});

test('chip labels read like sentences', () => {
	const label = (column: string) => column.charAt(0).toUpperCase() + column.slice(1);
	expect(
		describeRule({ column: 'status', op: 'eq', values: ['Done', 'Doing'] }, 'select', label)
	).toBe('Status: Done, Doing');
	expect(
		describeRule({ column: 'due', op: 'lt', values: [], relative: 'today' }, 'date', label)
	).toBe('Due: before Today');
	expect(describeRule({ column: 'done', op: 'eq', values: ['false'] }, 'bool', label)).toBe(
		'Done: unchecked'
	);
	expect(describeRule({ column: 'name', op: 'empty', values: [] }, 'text', label)).toBe(
		'Name: is empty'
	);
	expect(describeRule({ column: 'count', op: 'gte', values: ['2'] }, 'int', label)).toBe(
		'Count: ≥ 2'
	);
	expect(describeRule({ column: 'name', op: 'contains', values: [] }, 'text', label)).toBe('Name');
});
