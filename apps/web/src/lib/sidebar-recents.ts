import { displayName } from 'iris-core/client';
import type { Destination, resolveDestination } from './workspace-navigation';

/** A destination plus its display snapshot. Identity is only the destination;
 * the label, context, trash mark and reason are a display cache that paints on
 * open and is refreshed from local data afterwards, never used to navigate. */
export type RecentEntry = {
	destination: Destination;
	label: string;
	context: string;
	trash: boolean;
	loading: boolean;
	unavailable: string | null;
};
const limit = 8;
const identifier = (value: unknown): value is string =>
	typeof value === 'string' && value.length > 0;
function canonical(value: unknown): Destination | null {
	if (!value || typeof value !== 'object') return null;
	const { table, view, row } = value as Destination;
	if (
		!identifier(table) ||
		!(view === null || identifier(view)) ||
		!(row === null || identifier(row))
	)
		return null;
	return { table, view, row };
}
export function recentKey(destination: Destination): string {
	return JSON.stringify([destination.table, destination.view, destination.row]);
}
function bounded(values: RecentEntry[]): RecentEntry[] {
	const entries: RecentEntry[] = [];
	const seen = new Set<string>();
	for (const value of values) {
		const destination = canonical(value.destination);
		if (!destination || seen.has(recentKey(destination))) continue;
		seen.add(recentKey(destination));
		entries.push({ ...value, destination });
		if (entries.length === limit) break;
	}
	return entries;
}
/** Version 2 entries carry a snapshot; version 1 held identity tuples only. */
function stored(value: unknown, version: number): RecentEntry[] {
	const destination = canonical(value);
	if (!destination) return [];
	const { label, context, trash, unavailable } = value as Record<string, unknown>;
	return version === 2 &&
		typeof label === 'string' &&
		typeof context === 'string' &&
		typeof trash === 'boolean' &&
		(unavailable === null || typeof unavailable === 'string')
		? [{ destination, label, context, trash, loading: false, unavailable }]
		: [pending(destination)];
}
export function parseRecents(raw: string | null): RecentEntry[] {
	if (raw === null) return [];
	const value = JSON.parse(raw);
	if (!value || ![1, 2].includes(value.version) || !Array.isArray(value.entries))
		throw new Error('Recent destinations could not be read.');
	return bounded(value.entries.flatMap((entry: unknown) => stored(entry, value.version)));
}
export function serializeRecents(entries: RecentEntry[]): string {
	return JSON.stringify({
		version: 2,
		entries: bounded(entries).map(({ destination, label, context, trash, loading, unavailable }) =>
			loading ? destination : { ...destination, label, context, trash, unavailable }
		)
	});
}
export function rememberRecent(entries: RecentEntry[], entry: RecentEntry): RecentEntry[] {
	return canonical(entry.destination) ? bounded([entry, ...entries]) : entries;
}
function pending(destination: Destination): RecentEntry {
	return {
		destination,
		label: destination.row ?? destination.view ?? destination.table ?? '',
		context: destination.row
			? `Record · ${destination.table}`
			: destination.view
				? `View · ${destination.table}`
				: 'Table',
		trash: false,
		loading: true,
		unavailable: null
	};
}
/** Also builds a visit's snapshot from what the host shows when it records it.
 * A view names the entry, or joins a record's context, only when the destination
 * chose it: a plain table opens on its default view but is remembered as the table. */
export function describeRecent(
	destination: Destination,
	resolved: Pick<
		Awaited<ReturnType<typeof resolveDestination>>,
		'catalog' | 'table' | 'view' | 'row'
	>
): RecentEntry {
	const display = resolved.catalog.tables.find((t) => t.id === resolved.table)?.display;
	const view = destination.view ? resolved.view : null;
	const label = resolved.row
		? displayName(resolved.row, typeof display === 'string' ? display : undefined)
		: (view?.name ?? resolved.table);
	const base = pending(destination);
	return {
		...base,
		label,
		context: resolved.row && view ? `${base.context} · ${view.name}` : base.context,
		trash: !!resolved.row?.deleted_at,
		loading: false
	};
}
const same = (a: RecentEntry, b: RecentEntry) =>
	a.label === b.label &&
	a.context === b.context &&
	a.trash === b.trash &&
	a.loading === b.loading &&
	a.unavailable === b.unavailable;
/** Re-resolves the shown entries in order and publishes only when one changed. */
export async function loadRecentEntries(
	shown: RecentEntry[],
	resolve: (destination: Destination) => Promise<RecentEntry>,
	publish: (entries: RecentEntry[]) => void,
	current: () => boolean
) {
	const entries = [...shown];
	for (let i = 0; i < entries.length; i++) {
		if (!current()) return;
		let next: RecentEntry;
		try {
			next = await resolve(entries[i].destination);
		} catch (error) {
			next = {
				...entries[i],
				loading: false,
				unavailable: error instanceof Error ? error.message : String(error)
			};
		}
		if (!current()) return;
		if (same(next, entries[i])) continue;
		entries[i] = next;
		publish([...entries]);
	}
}
