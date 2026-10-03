import type { SearchHit, SavedViewList } from 'life-ui-core/client';

export type PaletteDestination =
	| { kind: 'table'; table: string; label: string; unavailable?: string }
	| { kind: 'view'; table: string; id: string; label: string; unavailable?: string };
export type PaletteEntry = PaletteDestination | ({ kind: 'record' } & SearchHit);
export type NavigationState = {
	destinations: PaletteDestination[];
	loading: boolean;
	error: string;
};

export function entryKey(entry: PaletteEntry): string {
	return JSON.stringify([entry.kind, entry.table, entry.kind === 'table' ? null : entry.id]);
}
export function paletteEntries(
	text: string,
	destinations: PaletteDestination[],
	hits: SearchHit[]
): PaletteEntry[] {
	const query = text.trim().toLowerCase();
	const matches = destinations.filter((entry) =>
		`${entry.label} ${entry.table}`.toLowerCase().includes(query)
	);
	return [
		...matches.filter((entry) => entry.kind === 'table'),
		...matches.filter((entry) => entry.kind === 'view'),
		...hits.map((hit) => ({ ...hit, kind: 'record' as const }))
	];
}
export function selectEntry(
	entries: PaletteEntry[],
	key: string | null,
	direction?: -1 | 1
): string | null {
	const enabled = entries.filter((entry) => !('unavailable' in entry && entry.unavailable));
	if (!enabled.length) return null;
	const index = enabled.findIndex((entry) => entryKey(entry) === key);
	if (direction === undefined) return index < 0 ? entryKey(enabled[0]) : key;
	return entryKey(
		enabled[
			index < 0
				? direction === 1
					? 0
					: enabled.length - 1
				: (index + direction + enabled.length) % enabled.length
		]
	);
}
export async function loadDestinations(
	tables: string[],
	list: (table: string) => Promise<SavedViewList>,
	publish: (state: NavigationState) => void,
	current: () => boolean
) {
	let destinations: PaletteDestination[] = tables.map((table) => ({
		kind: 'table',
		table,
		label: table
	}));
	const errors: string[] = [];
	const update = (loading: boolean) => publish({ destinations, loading, error: errors.join('\n') });
	if (!current()) return;
	update(true);
	// Request progressively: closing stops further reads, and record searches can
	// run between these serialized core operations. No metadata read per keystroke.
	for (const table of tables) {
		try {
			const result = await list(table);
			if (!current()) return;
			if (result.unavailable) errors.push(`${table}: ${result.unavailable}`);
			destinations = [
				...destinations,
				...result.views.map((view) => ({
					kind: 'view' as const,
					table: view.tbl,
					id: view.id,
					label: view.name,
					...(view.unavailable || !view.view || !view.definition
						? { unavailable: view.unavailable || 'This view is unavailable.' }
						: {})
				}))
			];
		} catch (error) {
			if (!current()) return;
			errors.push(
				`${table}: ${error instanceof Error ? error.message : 'Could not load saved views.'}`
			);
		}
		update(true);
	}
	update(false);
}
