import type { Filter, Property } from 'life-ui-core/client';

/** A Boolean property whose catalog description names exactly one sibling text
 * column is a flag with a reason: it gets a quick filter, and the reason column
 * shows inline while the filter is on. Nothing here knows any table's schema. */
// ponytail: description word match; a bool that names a text column for another purpose pairs with it.
export function flagFilters(properties: Property[]): { flag: Property; reason: Property }[] {
	return properties.flatMap((flag) => {
		if (flag.type !== 'bool') return [];
		const words = new Set(flag.description?.match(/[A-Za-z_]\w*/g) ?? []);
		const reasons = properties.filter(
			(p) =>
				p !== flag && p.tbl === flag.tbl && (p.type ?? 'text') === 'text' && words.has(p.col)
		);
		return reasons.length === 1 ? [{ flag, reason: reasons[0] }] : [];
	});
}

const isFlag = (f: Filter, column: string) =>
	f.column === column && f.op === 'eq' && f.value === true;
export const flagOn = (filters: Filter[], column: string) =>
	filters.some((f) => isFlag(f, column));
export const toggleFlag = (filters: Filter[], column: string): Filter[] =>
	flagOn(filters, column)
		? filters.filter((f) => !isFlag(f, column))
		: [...filters, { column, op: 'eq', value: true }];
