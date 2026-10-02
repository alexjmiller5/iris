import { expect, test } from 'vitest';
import { layoutSchema } from './schema-graph';
import type { Property, Row } from 'life-ui-core/client';

const tables: Row[] = [
	{ id: 'notes', name: 'Wrong physical name' },
	{ id: 'folders' },
	{ id: 'tags' }
];
const properties: Property[] = [
	{ tbl: 'notes', col: 'folder', type: 'ref', ref_table: 'folders' },
	{ tbl: 'notes', col: 'tags', type: 'multi_ref', ref_table: 'tags' },
	{ tbl: 'notes', col: 'body', type: 'markdown' },
	{ tbl: 'folders', col: 'parent', type: 'ref', ref_table: 'folders' }
];

test('maps catalog ids and only ref/multi_ref properties, including self references', () => {
	const graph = layoutSchema(tables, properties);
	expect(graph.nodes.map((node) => node.id)).toEqual(['folders', 'notes', 'tags']);
	expect(
		graph.edges.map(({ source, target, column, many }) => ({ source, target, column, many }))
	).toEqual([
		{ source: 'folders', target: 'folders', column: 'parent', many: false },
		{ source: 'notes', target: 'folders', column: 'folder', many: false },
		{ source: 'notes', target: 'tags', column: 'tags', many: true }
	]);
	expect(graph.nodes.find((node) => node.id === 'notes')?.columns).toBe(3);
	expect(graph.edges.every((edge) => edge.path && !/NaN|undefined/.test(edge.path))).toBe(true);
});

test('ignores missing endpoints, streams, deleted tables and duplicate catalog entries', () => {
	const graph = layoutSchema(
		[
			...tables,
			{ id: 'notes' },
			{ id: 'archive', deleted_at: 'deleted' },
			{ id: 'events', kind: 'stream' }
		],
		[
			...properties,
			properties[0],
			{ tbl: 'missing', col: 'ref', type: 'ref', ref_table: 'notes' },
			{ tbl: 'notes', col: 'missing', type: 'ref', ref_table: 'absent' },
			{ tbl: 'notes', col: 'archived', type: 'ref', ref_table: 'archive' },
			{ tbl: 'notes', col: 'text', type: 'text', ref_table: 'tags' }
		]
	);
	expect(graph.nodes.map((node) => node.id)).toEqual(['folders', 'notes', 'tags']);
	expect(graph.edges).toHaveLength(3);
});

test('input ordering does not move nodes, change edges or mutate the catalog', () => {
	const inputTables = structuredClone(tables);
	const inputProperties = structuredClone(properties);
	const first = layoutSchema(inputTables, inputProperties);
	expect(layoutSchema([...tables].reverse(), [...properties].reverse())).toEqual(first);
	expect(inputTables).toEqual(tables);
	expect(inputProperties).toEqual(properties);
});

test('explicit groups create separate bands without changing relationship identity', () => {
	const graph = layoutSchema(tables, properties, {
		notes: ' Writing ',
		folders: 'Writing',
		tags: ''
	});
	expect(graph.groups.map((group) => group.name)).toEqual(['Writing', 'Ungrouped']);
	expect(graph.nodes.filter((node) => node.group === 'Writing').map((node) => node.id)).toEqual([
		'folders',
		'notes'
	]);
	const tags = graph.nodes.find((node) => node.id === 'tags')!;
	expect(tags.y).toBeGreaterThan(graph.groups[0].y + graph.groups[0].height);
	expect(graph.edges.map((edge) => edge.id)).toEqual(
		layoutSchema(tables, properties).edges.map((edge) => edge.id)
	);
});

test('large grids stay inside their bounds with no overlapping table nodes', () => {
	const graph = layoutSchema(
		Array.from({ length: 11 }, (_, i) => ({ id: `table_${i}` })),
		[]
	);
	for (const node of graph.nodes) {
		expect(node.x).toBeGreaterThanOrEqual(0);
		expect(node.y).toBeGreaterThanOrEqual(0);
		expect(node.x + node.width).toBeLessThanOrEqual(graph.width);
		expect(node.y + node.height).toBeLessThanOrEqual(graph.height);
		for (const other of graph.nodes.filter((other) => other.id !== node.id)) {
			expect(
				node.x + node.width <= other.x ||
					other.x + other.width <= node.x ||
					node.y + node.height <= other.y ||
					other.y + other.height <= node.y
			).toBe(true);
		}
	}
});

test('empty and single-table catalogs need neither relationships nor special fake nodes', () => {
	expect(layoutSchema([], []).nodes).toEqual([]);
	expect(layoutSchema([], []).edges).toEqual([]);
	const graph = layoutSchema([{ id: 'notes' }], []);
	expect(graph.nodes.map((node) => node.id)).toEqual(['notes']);
	expect(graph.edges).toEqual([]);
	expect(graph.width).toBeLessThan(390);
});

test('distinct reference columns between the same tables retain their labels and paths', () => {
	const graph = layoutSchema(tables, [
		properties[0],
		{ ...properties[0], col: 'backup_folder', label: 'Backup folder' }
	]);
	expect(graph.edges.map((edge) => edge.label)).toEqual(['Backup folder', 'folder']);
	expect(new Set(graph.edges.map((edge) => edge.path)).size).toBe(2);
});
