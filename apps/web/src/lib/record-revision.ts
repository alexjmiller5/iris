import { validEditTimestamp, type Row } from 'iris-core/client';
export function editRevision(row: Row): string {
	const revision = row.updated_at;
	if (typeof revision !== 'string' || !validEditTimestamp(revision)) {
		throw new Error('This record has no valid revision. Refresh before editing.');
	}
	return revision;
}
