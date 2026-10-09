import type { CoreArgs, CoreResult, Row } from 'iris-core/client';
import type { WorkspaceDatabase } from './database';

/** Resolve on the bound service, then obtain values through ordinary replica sync. */
export async function resolveDerivedRecord(
	database: WorkspaceDatabase,
	connection: { endpoint: string; token: string },
	table: string,
	original: Row,
	column: string,
	download: Pick<CoreArgs<'sync'>, 'maxRows' | 'tables'>,
	isCurrent: () => boolean
): Promise<{ record: Row; result: CoreResult<'resolveDerived'> }> {
	const requireCurrent = () => {
		if (!isCurrent()) throw new Error('The editor changed. Your draft has been kept.');
	};
	requireCurrent();
	if (
		typeof original.id !== 'string' ||
		typeof original.updated_at !== 'string' ||
		original.deleted_at != null
	)
		throw new Error('Open a saved, active record before resolving.');
	const result = await database.request('resolveDerived', {
		...connection,
		table,
		id: original.id,
		column,
		expectedUpdatedAt: original.updated_at
	});
	requireCurrent();
	await database.request('sync', { ...connection, ...download });
	requireCurrent();
	const [record] = await database.request('rows', {
		view: { table, filters: [{ column: 'id', op: 'eq', value: original.id }], limit: 1 }
	});
	requireCurrent();
	if (
		!record ||
		record.id !== original.id ||
		record.deleted_at != null ||
		(result.derived > 0 && record.updated_at === original.updated_at)
	)
		throw new Error('The resolved record is not available locally yet. Sync and reopen it.');
	return { record, result };
}
