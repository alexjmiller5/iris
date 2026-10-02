import type { Property, Row } from 'life-ui-core/client';

const compare = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

export function layoutSchema(
	tables: Row[],
	properties: Property[],
	labels: Record<string, string> = {}
) {
	const ids = [
		...new Set(
			tables
				.filter(
					(table) =>
						typeof table.id === 'string' &&
						table.id &&
						table.deleted_at == null &&
						(table.kind == null || table.kind === 'table')
				)
				.map((table) => table.id as string)
		)
	].sort(compare);
	const buckets = new Map<string, string[]>();
	for (const id of ids) {
		const group = typeof labels[id] === 'string' ? labels[id].trim() : '';
		buckets.set(group, [...(buckets.get(group) ?? []), id]);
	}
	const columns = Math.min(3, Math.max(1, ...[...buckets.values()].map((ids) => ids.length)));
	const width = 80 + columns * 208 + (columns - 1) * 80;
	const nodes: {
		id: string;
		group: string;
		x: number;
		y: number;
		width: number;
		height: number;
		columns: number;
	}[] = [];
	const groups: { id: string; name: string; y: number; height: number }[] = [];
	let top = 0;
	for (const group of [...buckets.keys()].sort((a, b) =>
		a === '' ? 1 : b === '' ? -1 : compare(a, b)
	)) {
		const members = buckets.get(group)!;
		const height = 56 + Math.ceil(members.length / columns) * 128;
		groups.push({
			id: group,
			name: group || (buckets.size === 1 ? 'Tables' : 'Ungrouped'),
			y: top,
			height
		});
		members.forEach((id, index) =>
			nodes.push({
				id,
				group,
				x: 40 + (index % columns) * 288,
				y: top + 56 + Math.floor(index / columns) * 128,
				width: 208,
				height: 72,
				columns: new Set(
					properties.filter((property) => property.tbl === id).map((property) => property.col)
				).size
			})
		);
		top += height + 20;
	}
	const byId = new Map(nodes.map((node) => [node.id, node]));
	const references = new Map<string, Property>();
	for (const property of properties) {
		if (
			(property.type === 'ref' || property.type === 'multi_ref') &&
			byId.has(property.tbl ?? '') &&
			byId.has(property.ref_table ?? '') &&
			typeof property.col === 'string'
		) {
			references.set(
				JSON.stringify([property.tbl, property.col, property.ref_table, property.type]),
				property
			);
		}
	}
	const edges = [...references]
		.sort(([a], [b]) => compare(a, b))
		.map(([id, property], index) => {
			const from = byId.get(property.tbl!)!,
				to = byId.get(property.ref_table!)!;
			// ponytail: five visual lanes; use routed edges if dense catalogs need more separation.
			const lane = ((index % 5) - 2) * 8;
			let path: string, x: number, y: number;
			if (from.id === to.id) {
				const bottom = from.y + from.height;
				path = `M ${from.x + 144} ${bottom} C ${from.x + 220} ${bottom + 54 + lane} ${from.x - 12} ${bottom + 54 + lane} ${from.x + 64} ${bottom}`;
				x = from.x + 104;
				y = bottom + 42 + lane;
			} else if (from.y === to.y) {
				const right = to.x > from.x;
				const sx = from.x + (right ? from.width : 0),
					tx = to.x + (right ? 0 : to.width);
				const sy = from.y + 36 + lane,
					ty = to.y + 36 + lane;
				x = (sx + tx) / 2;
				y = (sy + ty) / 2 - 8;
				path = `M ${sx} ${sy} C ${x} ${sy} ${x} ${ty} ${tx} ${ty}`;
			} else {
				const down = to.y > from.y;
				const sx = from.x + 104 + lane,
					tx = to.x + 104 + lane;
				const sy = from.y + (down ? from.height : 0),
					ty = to.y + (down ? 0 : to.height);
				const mid = (sy + ty) / 2;
				x = (sx + tx) / 2 + 8;
				y = mid - 8;
				path = `M ${sx} ${sy} C ${sx} ${mid} ${tx} ${mid} ${tx} ${ty}`;
			}
			return {
				id,
				source: from.id,
				target: to.id,
				column: property.col,
				label: property.label || property.col,
				many: property.type === 'multi_ref',
				path,
				x,
				y
			};
		});
	return { nodes, edges, groups, width, height: Math.max(184, top - 20) };
}
