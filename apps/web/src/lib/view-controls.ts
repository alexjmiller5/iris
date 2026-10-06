import type { Filter, SavedViewDefinition, Sort, View } from 'life-ui-core/client';
import { calendarContext } from './calendar-context';

export function editSort(sorts: Sort[], index: number, patch: Partial<Sort>): Sort[] {
	return sorts.map((sort, i) => (i === index ? { ...sort, ...patch } : { ...sort }));
}
export function parseFilter(
	column: string,
	op: Filter['op'],
	text: string,
	type: string,
	today: boolean
): Filter {
	if (op === 'empty' || op === 'not_empty') return { column, op };
	if (today) {
		if (!['date', 'datetime'].includes(type) || op === 'contains')
			throw new Error('Today requires a date comparison.');
		return { column, op, relative: 'today' };
	}
	let value: Filter['value'] = text;
	if (['number', 'int'].includes(type)) {
		if (!text.trim() || !Number.isFinite(Number(text)))
			throw new Error('Enter a number for this filter.');
		value = Number(text);
	} else if (type === 'bool') {
		if (!['true', 'false'].includes(text)) throw new Error('Choose True or False for this filter.');
		value = text === 'true';
	}
	return { column, op, value };
}
export function queryDefinition(
	table: string,
	definition: SavedViewDefinition,
	now = new Date()
): View {
	const { filters, groups, sort, search, trash } = definition;
	const relative = [...(filters ?? []), ...(groups ?? []).flatMap((g) => g.filters)].some(
		(f) => f.relative
	);
	if (relative && !definition.timeZone) throw new Error('Choose a timezone for Today.');
	return {
		table,
		filters,
		groups,
		sort,
		search,
		trash,
		...(relative ? { calendar: calendarContext(definition.timeZone!, now) } : {})
	};
}
