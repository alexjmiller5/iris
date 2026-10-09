import type { WorkspaceDatabase } from './database';
import type { Row, SavedViewRecord } from 'iris-core/client';

/** Links carry identities only; view settings live in the saved view. */
export type Destination = {
	table: string | null;
	view: string | null;
	row: string | null;
};
export function readDestination(url: URL): Destination {
	const read = (key: string) => {
		const values = url.searchParams.getAll(key);
		if (values.length > 1 || values[0] === '')
			throw new Error(
				'This link has an empty or repeated destination. Copy a new link from the workspace.'
			);
		return values[0] ?? null;
	};
	const destination: Destination = { table: read('table'), view: read('view'), row: read('row') };
	if (!destination.table && (destination.view || destination.row))
		throw new Error('This link needs a table. Copy a new link from the workspace.');
	return destination;
}
export function destinationURL(url: URL, destination: Destination, retainProposal = false): URL {
	const result = new URL(url.pathname, url.origin);
	if (retainProposal) {
		const proposals = url.searchParams.getAll('proposal');
		if (
			proposals.length > 1 ||
			(proposals.length === 1 &&
				(proposals[0] === '' ||
					new TextEncoder().encode(proposals[0]).length > 256 ||
					/[\u0000-\u001f\u007f]/.test(proposals[0])))
		)
			throw new Error('This review link is invalid. Copy a new proposal link.');
		if (proposals.length === 1) result.searchParams.set('proposal', proposals[0]);
	}
	for (const key of ['table', 'view', 'row'] as const) {
		if (destination[key] !== null) result.searchParams.set(key, destination[key]);
	}
	return result;
}
export async function resolveDestination(
	workspace: Pick<WorkspaceDatabase, 'request'>,
	destination: Destination,
	fallback: string
) {
	const { catalog } = await workspace.request('snapshot');
	const table =
		destination.table ??
		(catalog.tables.some((t) => t.id === fallback)
			? fallback
			: String(catalog.tables[0]?.id ?? ''));
	if (table && !catalog.tables.some((t) => t.id === table))
		throw new Error(
			'The linked table is not available in this workspace. Open the matching workspace or include the table and sync.'
		);
	let view: SavedViewRecord | null = null;
	let defaultNotice: string | null = null;
	if (destination.view) {
		const result = await workspace.request('listViews', { table });
		view = result.views.find((v) => v.id === destination.view) ?? null;
		if (!view || view.tbl !== table || view.unavailable || !view.definition || !view.view) {
			throw new Error(
				view?.unavailable ??
					result.unavailable ??
					'The linked view is not available in this table. Sync or choose another saved view.'
			);
		}
	}
	if (table && !destination.view) {
		// Every table opens on a real saved view, created when it has none.
		const preferred = await workspace
			.request('ensureDefaultView', { table })
			.catch(() => workspace.request('getViewDefault', { table }));
		view = preferred.view;
		defaultNotice = preferred.unavailable;
	}
	let row: Row | null = null;
	if (destination.row) {
		const first = view?.definition?.trash ?? false;
		for (const trash of [first, !first]) {
			const rows = await workspace.request('rows', {
				view: {
					table,
					filters: [{ column: 'id', op: 'eq', value: destination.row }],
					limit: 1,
					trash
				}
			});
			row = rows[0] ?? null;
			if (row) break;
		}
		if (!row)
			throw new Error(
				'The linked record is not available locally. It may be missing or outside this replica. Include its table and sync, or choose another record.'
			);
	}
	return { catalog, table, view, row, defaultNotice };
}
