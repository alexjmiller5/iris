import type { WorkspaceDatabase } from './database';

/** Prepare only. The caller confirms discard and installs the new draft synchronously. */
export async function prepareDuplicate(
	workspace: Pick<WorkspaceDatabase, 'request'>,
	table: string,
	id: string,
	current: () => boolean
) {
	const { catalog } = await workspace.request('snapshot');
	if (!current()) return null;
	if (!catalog.tables.some((t) => t.id === table))
		throw new Error('This table is no longer available locally.');
	const permission = await workspace.request('writeability', { table });
	if (!current()) return null;
	if (!permission.writable)
		throw new Error(permission.reason?.message ?? 'This table is read-only.');
	const rows = await workspace.request('rows', {
		view: { table, filters: [{ column: 'id', op: 'eq', value: id }], limit: 1 }
	});
	if (!current()) return null;
	const row = rows[0];
	if (!row || row.id !== id || row.deleted_at != null)
		throw new Error('This record is no longer available locally.');
	return { catalog, permission, row };
}
