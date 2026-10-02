import type { WorkspaceDatabase } from './database';
import type { Row, SyncResult } from 'life-ui-core/client';

declare const database: WorkspaceDatabase;
const rows: Promise<Row[]> = database.request('rows', { view: { table: 'items' } });
const sync: Promise<SyncResult> = database.request('sync', {
	endpoint: 'https://hub.example.test',
	token: 'fixture'
});
// @ts-expect-error Rows require a generated View with a table.
database.request('rows', { view: {} });
// @ts-expect-error Operation results are paired with their method.
const wrong: Promise<SyncResult> = database.request('rows', { view: { table: 'items' } });
// @ts-expect-error Credentials belong to the host and are required for sync.
database.request('sync', { endpoint: 'https://hub.example.test' });
// @ts-expect-error Unknown methods cannot be dispatched.
database.request('erase');
void rows;
void sync;
void wrong;
