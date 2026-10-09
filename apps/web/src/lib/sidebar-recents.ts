import { displayName } from 'iris-core/client';
import type { Destination, resolveDestination } from './workspace-navigation';

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
function bounded(values: unknown[]): Destination[] {
	const entries: Destination[] = [];
	const seen = new Set<string>();
	for (const value of values) {
		const destination = canonical(value);
		if (!destination || seen.has(recentKey(destination))) continue;
		seen.add(recentKey(destination));
		entries.push(destination);
		if (entries.length === limit) break;
	}
	return entries;
}
export function parseRecents(raw: string | null): Destination[] {
	if (raw === null) return [];
	const value = JSON.parse(raw);
	if (!value || value.version !== 1 || !Array.isArray(value.entries))
		throw new Error('Recent destinations could not be read.');
	return bounded(value.entries);
}
export function serializeRecents(destinations: Destination[]): string {
	return JSON.stringify({ version: 1, entries: bounded(destinations) });
}
export function rememberRecent(
	destinations: Destination[],
	destination: Destination
): Destination[] {
	return canonical(destination) ? bounded([destination, ...destinations]) : destinations;
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
export function describeRecent(
	destination: Destination,
	resolved: Awaited<ReturnType<typeof resolveDestination>>
): RecentEntry {
	const display = resolved.catalog.tables.find((t) => t.id === resolved.table)?.display;
	const label = resolved.row
		? displayName(resolved.row, typeof display === 'string' ? display : undefined)
		: (resolved.view?.name ?? resolved.table);
	const base = pending(destination);
	return {
		...base,
		label,
		context:
			resolved.row && resolved.view ? `${base.context} · ${resolved.view.name}` : base.context,
		trash: !!resolved.row?.deleted_at,
		loading: false
	};
}
export async function loadRecentEntries(
	destinations: Destination[],
	resolve: (destination: Destination) => Promise<RecentEntry>,
	publish: (entries: RecentEntry[]) => void,
	current: () => boolean
) {
	if (!current()) return;
	const entries = destinations.map(pending);
	publish([...entries]);
	for (let i = 0; i < entries.length; i++) {
		if (!current()) return;
		try {
			const resolved = await resolve(entries[i].destination);
			if (!current()) return;
			entries[i] = resolved;
		} catch (error) {
			if (!current()) return;
			entries[i] = {
				...entries[i],
				loading: false,
				unavailable: error instanceof Error ? error.message : String(error)
			};
		}
		publish([...entries]);
	}
}
