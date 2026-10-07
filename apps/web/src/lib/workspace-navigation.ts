import type { WorkspaceDatabase } from './database';
import type { Row, SavedViewRecord, SavedViewDefinition } from 'life-ui-core/client';

export type Destination = {
	table: string | null;
	view: string | null;
	row: string | null;
	state?: SavedViewDefinition;
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
	const state = read('state');
	if (state !== null) {
		if (new TextEncoder().encode(state).length > 16384)
			throw new Error('This view link is too large. Save the view and copy its link.');
		const definition = JSON.parse(state);
		if (
			!definition ||
			typeof definition !== 'object' ||
			Array.isArray(definition) ||
			Object.hasOwn(definition, 'actions')
		)
			throw new Error('This link has invalid view settings.');
		destination.state = definition;
	}
	if (!destination.table && (destination.view || destination.row || destination.state))
		throw new Error('This link needs a table. Copy a new link from the workspace.');
	return destination;
}
export function destinationURL(url: URL, destination: Destination): URL {
	const result = new URL(url.pathname, url.origin);
	for (const key of ['table', 'view', 'row'] as const) {
		if (destination[key] !== null) result.searchParams.set(key, destination[key]);
	}
	if (destination.state) {
		const { actions: _actions, ...state } = destination.state;
		const text = JSON.stringify(state);
		if (new TextEncoder().encode(text).length > 16384)
			throw new Error('This view link is too large. Save the view and copy its link.');
		result.searchParams.set('state', text);
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
	if (table && !destination.view && !destination.row && !destination.state) {
		const preferred = await workspace.request('getViewDefault', { table });
		view = preferred.view;
		defaultNotice = preferred.unavailable;
	}
	let definition: SavedViewDefinition | null = null;
	if (destination.state) {
		if (Object.hasOwn(destination.state, 'actions'))
			throw new Error('This link has invalid view settings.');
		// URI settings never authorize actions; only the displayed saved revision does.
		const resolved = await workspace.request('resolveViewDefinition', {
			table,
			definition: {
				...destination.state,
				...(view?.definition?.actions ? { actions: view.definition.actions } : {})
			}
		});
		definition = resolved.definition;
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
	return { catalog, table, view, row, defaultNotice, definition };
}
