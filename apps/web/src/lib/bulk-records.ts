import type { Row } from 'iris-core/client';
import type { WorkspaceDatabase } from './database';
import { editRevision } from './record-revision';

export type BulkRecordResult = {
	id: string;
	status: 'succeeded' | 'failed' | 'unattempted';
	row?: Row;
	error?: string;
};
export async function runBulkRecords(
	database: Pick<WorkspaceDatabase, 'request'>,
	table: string,
	selectedIds: readonly string[],
	values: Row,
	options: {
		signal?: AbortSignal;
		isCurrent?: () => boolean;
		onProgress?: (results: BulkRecordResult[]) => void;
	} = {}
): Promise<BulkRecordResult[]> {
	const ids = [...selectedIds];
	if (
		!ids.length ||
		ids.some((id) => typeof id !== 'string' || !id.length) ||
		new Set(ids).size !== ids.length
	)
		throw Error('Choose a nonempty selection with no duplicate record IDs.');
	if (
		Object.keys(values).some((column) =>
			['id', 'created_at', 'updated_at', 'hub_at'].includes(column)
		)
	)
		throw Error('Bulk changes cannot replace managed record fields.');
	if (!Object.keys(values).length) throw Error('Choose a property to change.');
	const patch = structuredClone(values);
	const results: BulkRecordResult[] = ids.map((id) => ({ id, status: 'unattempted' }));
	const stopped = () => options.signal?.aborted || (options.isCurrent && !options.isCurrent());
	const publish = () => options.onProgress?.(results.map((result) => ({ ...result })));
	if (stopped()) return results;
	const permission = await database.request('writeability', { table });
	if (stopped()) return results;
	if (!permission.writable) throw Error(permission.reason?.message ?? 'This table is read-only.');
	for (const [index, id] of ids.entries()) {
		if (stopped()) break;
		let writing = false;
		try {
			const rows = await database.request('rows', {
				view: { table, filters: [{ column: 'id', op: 'eq', value: id }], limit: 2 }
			});
			if (stopped()) break;
			const row = rows[0];
			if (rows.length !== 1 || row.id !== id || row.deleted_at != null)
				throw Error('This record is no longer available locally.');
			const expectedUpdatedAt = editRevision(row);
			writing = true;
			const receipt = await database.request('write', {
				table,
				patch: { ...patch, id },
				expectedUpdatedAt
			});
			// Cancellation cannot revoke a successful commit. Keep its receipt even
			// when the host changed while the write was in flight; stop before the next row.
			results[index] = { id, status: 'succeeded', row: receipt };
		} catch (cause) {
			if (!writing && stopped()) break;
			results[index] = {
				id,
				status: 'failed',
				error: cause instanceof Error ? cause.message : 'Record change failed.'
			};
		}
		publish();
	}
	return results;
}
