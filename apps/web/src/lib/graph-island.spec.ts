import { expect, test } from 'vitest';
import { parseGraphInput } from './graph-island';

test('native JSON catalogs retain reference metadata and default missing groups', () => {
	const input = {
		tables: [{ id: 'notes', display: 'title' }],
		properties: [{ tbl: 'notes', col: 'related', type: 'ref', ref_table: 'notes' }]
	};
	expect(parseGraphInput(input)).toEqual({ ...input, groups: {} });
});

test('renders copy native input so subsequent host edits cannot silently change the graph', () => {
	const input = {
		tables: [{ id: 'notes' }],
		properties: [{ tbl: 'notes', col: 'title', type: 'text' }],
		groups: { notes: 'Writing' }
	};
	const parsed = parseGraphInput(input);
	input.tables[0].id = 'changed';
	input.properties[0].col = 'changed';
	input.groups.notes = 'Changed';
	expect(parsed.tables[0].id).toBe('notes');
	expect(parsed.properties[0].col).toBe('title');
	expect(parsed.groups.notes).toBe('Writing');
});

test.each([
	null,
	[],
	{},
	{ tables: {}, properties: [] },
	{ tables: [null], properties: [] },
	{ tables: [{ id: 1 }], properties: [] },
	{ tables: [{ id: '' }], properties: [] },
	{ tables: [], properties: [null] },
	{ tables: [], properties: [{ tbl: 'notes', col: 42 }] },
	{ tables: [], properties: [{ col: 'title' }] },
	{ tables: [], properties: [], groups: [] },
	{ tables: [], properties: [], groups: { notes: false } }
])('malformed native input fails before replacing a displayed catalog (%j)', (input) => {
	expect(() => parseGraphInput(input)).toThrow(/graph/i);
});

test('labels remain literal data, including markup and object prototype key names', () => {
	const input = JSON.parse(
		'{"tables":[{"id":"__proto__"}],"properties":[],"groups":{"__proto__":"<script>bad()</script>"}}'
	);
	const parsed = parseGraphInput(input);
	expect(Object.hasOwn(parsed.groups, '__proto__')).toBe(true);
	expect(parsed.groups.__proto__).toBe('<script>bad()</script>');
	expect(Object.getPrototypeOf(parsed.groups)).toBe(Object.prototype);
});
