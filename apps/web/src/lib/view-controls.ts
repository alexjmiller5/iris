import type { Filter, Row, SavedViewDefinition, Sort, View } from 'iris-core/client';
import { calendarContext, localTimeInstant } from './calendar-context';

export function parseDayStart(time: string): number {
	if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) throw new Error('Choose a valid day start time.');
	const [hour, minute] = time.split(':').map(Number);
	return hour * 60 + minute;
}

export function editSort(sorts: Sort[], index: number, patch: Partial<Sort>): Sort[] {
	return sorts.map((sort, i) => (i === index ? { ...sort, ...patch } : { ...sort }));
}
/** Move one item to a new index, keeping the rest in order. */
export function moveItem<T>(list: T[], from: number, to: number): T[] {
	const next = [...list];
	next.splice(to, 0, ...next.splice(from, 1));
	return next;
}
export function initialFilterValue(type: string): string {
	return ['number', 'int'].includes(type) ? '0' : type === 'bool' ? 'false' : '';
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
		if (!['date', 'datetime', 'date_or_datetime'].includes(type) || op === 'contains')
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
	return {
		table,
		filters,
		groups,
		sort,
		search,
		trash,
		...(relative
			? { calendar: calendarContext(definition.timeZone, now, definition.dayStartMinutes) }
			: {})
	};
}

/** When the next timed value a relative-Now filter compares with comes due later in
 * the current policy day, or null. Only timed values count: a date-only value is
 * due all day and the day boundary already refreshes the view. */
export async function nextDue(
	read: (view: View) => Promise<Row[]>,
	table: string,
	definition: SavedViewDefinition,
	now = new Date()
): Promise<number | null> {
	const { filters, groups } = definition;
	const columns = new Set(
		[...(filters ?? []), ...(groups ?? []).flatMap((g) => g.filters)]
			.filter((f) => f.relative === 'now')
			.map((f) => f.column)
	);
	const calendar = calendarContext(definition.timeZone, now, definition.dayStartMinutes);
	let next: number | null = null;
	for (const column of columns) {
		// ponytail: the 200 earliest by text; local times and instants interleave
		// loosely, so a day with more timed values could refresh a little late.
		const rows = await read({
			table,
			calendar,
			columns: ['id', column],
			filters: [
				{ column, op: 'gt', relative: 'now' },
				{ column, op: 'eq', relative: 'today' }
			],
			sort: [{ column, direction: 'asc' }],
			limit: 200
		});
		for (const row of rows) {
			const value = String(row[column]);
			const at = localTimeInstant(value, definition.timeZone) ?? Date.parse(value);
			if (Number.isFinite(at) && at > now.getTime() && (next === null || at < next)) next = at;
		}
	}
	return next;
}
