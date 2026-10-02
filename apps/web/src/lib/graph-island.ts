import type { Property, Row } from 'life-ui-core/client';

export type GraphData = {
	tables: Row[];
	properties: Property[];
	groups: Record<string, string>;
};
export type GraphMessage =
	{ type: 'openTable'; table: string } | { type: 'groups'; groups: Record<string, string> };

const record = (value: unknown): value is Record<string, unknown> =>
	value !== null &&
	typeof value === 'object' &&
	[Object.prototype, null].includes(Object.getPrototypeOf(value));
const named = (value: unknown): value is string => typeof value === 'string' && value.length > 0;

/** Validate before replacing the current view; native callers pass parsed JSON. */
export function parseGraphInput(value: unknown): GraphData {
	if (
		!record(value) ||
		!Array.isArray(value.tables) ||
		!value.tables.every((table) => record(table) && named(table.id)) ||
		!Array.isArray(value.properties) ||
		!value.properties.every(
			(property) =>
				record(property) &&
				named(property.tbl) &&
				named(property.col) &&
				['type', 'label', 'ref_table'].every(
					(key) => property[key] == null || typeof property[key] === 'string'
				)
		) ||
		(value.groups !== undefined &&
			(!record(value.groups) ||
				!Object.values(value.groups).every((group) => typeof group === 'string')))
	) {
		throw new Error('Invalid graph input: expected catalog tables, properties and string groups.');
	}
	return {
		tables: value.tables.map((table) => ({ ...table })),
		properties: value.properties.map((property) => ({ ...property })) as Property[],
		groups: { ...(value.groups as Record<string, string> | undefined) }
	};
}
