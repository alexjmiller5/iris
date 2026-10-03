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

// @ts-expect-error Online operations require the host's session credential.
database.request('remoteRows', { endpoint: 'https://hub.example.test', table: 'items' });
// @ts-expect-error A lookup requires the stable record ID.
database.request('remoteRow', {
	endpoint: 'https://hub.example.test',
	token: 'fixture',
	table: 'items'
});

const incomingSources: Promise<import('life-ui-core/client').ReferenceSource[]> = database.request(
	'referenceSources',
	{ table: 'items' }
);
const incomingPage: Promise<import('life-ui-core/client').ReferencedByPage> = database.request(
	'referencedBy',
	{ table: 'items', rowId: 'one', sourceTable: 'entries', column: 'owner', limit: 20, offset: 0 }
);
// @ts-expect-error Incoming pages require the source column, never a free-form query.
database.request('referencedBy', { table: 'items', rowId: 'one', sourceTable: 'entries' });
void incomingSources;
void incomingPage;
