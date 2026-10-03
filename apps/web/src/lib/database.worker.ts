/// <reference lib="webworker" />
import SQLiteFactory from '../../../../vendor/wa-sqlite/wa-sqlite.mjs';
import wasmUrl from '../../../../vendor/wa-sqlite/wa-sqlite.wasm?url';
import * as SQLite from 'wa-sqlite';
import { OPFSCoopSyncVFS } from 'wa-sqlite/src/examples/OPFSCoopSyncVFS.js';
import {
	CORE_CONTRACT_HASH,
	createCoreHandlers,
	createHttpHub,
	initCore,
	qident,
	readCatalog,
	syncStatus,
	type Row,
	type SqlDriver,
	type Value
} from 'life-ui-core/client';
import { prepareLocalViews } from '../../../../scripts/local-views';
import type { DatabaseRequest, WorkspaceSnapshot } from './database-contract';

const scope = self as unknown as DedicatedWorkerGlobalScope;
const respond = (data: Record<string, unknown>) =>
	scope.postMessage({ ...data, contractHash: CORE_CONTRACT_HASH });
let sqlite: ReturnType<typeof SQLite.Factory>;
let connection: number | undefined;
let databaseName: string | undefined;
let channel: BroadcastChannel | undefined;
let queue = Promise.resolve();
let reading = false;
let statementReadOnly: (statement: number) => number;

const db: SqlDriver = {
	async all(sql: string, params: Value[] = []) {
		if (connection === undefined) throw new Error('Open a workspace first.');
		const statements: number[] = [];
		reading = true;
		try {
			// Retain handles and inspect the complete input before stepping anything.
			// SQLite parses statement boundaries, including literals and comments.
			for await (const statement of sqlite.statements(connection, sql, { unscoped: true })) {
				statements.push(statement);
				if (statements.length > 1) throw new Error('Expected one read-only SQL statement.');
			}
			if (statements.length !== 1 || !statementReadOnly(statements[0]))
				throw new Error('Expected one read-only SQL statement.');
			const statement = statements[0];
			sqlite.bind_collection(statement, params);
			const columns = sqlite.column_names(statement);
			const rows: Row[] = [];
			while ((await sqlite.step(statement)) === SQLite.SQLITE_ROW) {
				const values = sqlite.row(statement);
				rows.push(Object.fromEntries(columns.map((column, i) => [column, values[i]])));
			}
			return rows;
		} finally {
			try {
				for (const statement of statements) await sqlite.finalize(statement);
			} finally {
				reading = false;
			}
		}
	},
	async run(sql, params = []) {
		if (connection === undefined) throw new Error('Open a workspace first.');
		// Trusted schema replay can contain dependent DDL statements. Prepare and
		// execute those sequentially, separately from the read-only query path.
		for await (const statement of sqlite.statements(connection, sql)) {
			sqlite.bind_collection(statement, params);
			while ((await sqlite.step(statement)) === SQLite.SQLITE_ROW) {
				/* Discard RETURNING rows. */
			}
		}
		return sqlite.changes(connection!);
	},
	async transaction(body) {
		await db.run('BEGIN IMMEDIATE');
		try {
			const result = await body();
			await db.run('COMMIT');
			return result;
		} catch (error) {
			await db.run('ROLLBACK');
			throw error;
		}
	}
};

async function seedDemo() {
	// Synthetic data lives only in the separate, unsyncable demo database.
	const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
		updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
		deleted_at TEXT, hub_at TEXT`;
	const tables = {
		notes: 'title TEXT, status TEXT, body TEXT',
		catalog_tables:
			'kind TEXT, display TEXT, purpose TEXT, id_semantics TEXT, provenance TEXT, owner TEXT, consumers TEXT, description TEXT',
		catalog_properties:
			'tbl TEXT, col TEXT, label TEXT, sort INTEGER, type TEXT, required INTEGER, default_value TEXT, options TEXT, options_sql TEXT, min_items INTEGER, max_items INTEGER, pattern TEXT, ref_table TEXT, derived_by TEXT, inputs TEXT, immutable INTEGER, deprecated INTEGER, description TEXT, source TEXT, source_ref TEXT',
		catalog_rules:
			'scope TEXT, tbl TEXT, col TEXT, kind TEXT, text TEXT, sql TEXT, cmd TEXT, enforce INTEGER',
		history: 'tbl TEXT, row_id TEXT, col TEXT, old TEXT, new TEXT, origin TEXT'
	};
	for (const [name, columns] of Object.entries(tables)) {
		const ddl = `CREATE TABLE ${qident(name)} (${system}, ${columns})`;
		await db.run(ddl);
		await db.run(
			"INSERT INTO _schema_log(applied_at,ddl) VALUES (strftime('%Y-%m-%dT%H:%M:%fZ','now'),?)",
			[ddl]
		);
	}
	await db.run('INSERT INTO catalog_tables(id,kind,display,purpose) VALUES (?,?,?,?)', [
		'notes',
		'table',
		'title',
		'A place to write.'
	]);
	for (const [col, label, sort, type, required, options, defaultValue] of [
		['title', 'Title', 0, 'text', 1, null, null],
		['status', 'Status', 1, 'select', 0, JSON.stringify([{ v: 'Draft' }, { v: 'Ready' }]), 'Draft'],
		['body', 'Body', 2, 'markdown', 0, null, null]
	] satisfies Value[][]) {
		await db.run(
			'INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required,options,default_value) VALUES (?,?,?,?,?,?,?,?,?)',
			[`notes.${col}`, 'notes', col, label, sort, type, required, options, defaultValue]
		);
	}
	await db.run('INSERT INTO notes(title,status,body) VALUES (?,?,?)', [
		'A place to start',
		'Draft',
		'# A place to start\n\nYour notes live here.'
	]);
}

async function snapshot(): Promise<WorkspaceSnapshot> {
	const status = await syncStatus(db);
	return {
		catalog: await readCatalog(db),
		status,
		lastSync: status.lastSuccessfulSync,
		skipped: JSON.parse(
			String(
				(await db.all("SELECT value FROM _core_state WHERE key='skipped_tables'"))[0]?.value ?? '[]'
			)
		) as string[],
		rejected: (await db.all('SELECT * FROM _core_rejected ORDER BY tbl,row_id')).map((row) => ({
			...row,
			row: JSON.parse(String(row.row)),
			errors: JSON.parse(String(row.errors))
		}))
	};
}

async function migrateDemo() {
	// Demo-only backfill; keep existing rows and their revisions intact.
	const columns = await db.all('PRAGMA table_info(notes)');
	if (!columns.some((column) => column.name === 'related')) {
		const ddl = 'ALTER TABLE notes ADD COLUMN related TEXT';
		await db.run(ddl);
		await db.run(
			"INSERT INTO _schema_log(applied_at,ddl) VALUES (strftime('%Y-%m-%dT%H:%M:%fZ','now'),?)",
			[ddl]
		);
	}
	await db.run(
		'INSERT OR IGNORE INTO catalog_properties(id,tbl,col,label,sort,type,ref_table) VALUES (?,?,?,?,?,?,?)',
		['notes.related', 'notes', 'related', 'Related note', 3, 'ref', 'notes']
	);
}

const local = createCoreHandlers(
	db,
	() => {
		throw new Error('No hub connection.');
	},
	'life-ui'
);

async function dispatch(request: DatabaseRequest) {
	const { method, args } = request;
	if (method === 'open') {
		if (args.demo !== undefined && typeof args.demo !== 'boolean')
			throw new Error('demo must be a boolean.');
		const name = args.demo ? 'life-ui-demo' : 'life-ui';
		if (databaseName && name !== databaseName)
			throw new Error('Close this database before switching workspaces.');
		if (connection !== undefined) return snapshot();
		if (
			!navigator.storage?.getDirectory ||
			typeof FileSystemFileHandle === 'undefined' ||
			!('createSyncAccessHandle' in FileSystemFileHandle.prototype)
		) {
			throw new Error(
				'Persistent storage (OPFS) is unavailable in this browser. No workspace was opened.'
			);
		}
		const module = await SQLiteFactory({ locateFile: () => wasmUrl });
		sqlite = SQLite.Factory(module);
		// Exported by this WASM build, but not wrapped in wa-sqlite's typed API.
		statementReadOnly = module.cwrap('sqlite3_stmt_readonly', 'number', ['number']);
		try {
			const vfs = await OPFSCoopSyncVFS.create('life-ui', module);
			sqlite.vfs_register(vfs, true);
			connection = await sqlite.open_v2(name, undefined, vfs.name);
			sqlite.set_authorizer(
				connection,
				(_, action, name, detail) => {
					if (!reading) return SQLite.SQLITE_OK;
					// The authorizer runs during preparation too: reject connection control
					// and mutating PRAGMAs before they can act. FTS5 reads data_version on reopen.
					if (action === SQLite.SQLITE_PRAGMA)
						return ['table_info', 'table_xinfo', 'foreign_key_list', 'data_version'].includes(
							name?.toLowerCase() ?? ''
						)
							? SQLite.SQLITE_OK
							: SQLite.SQLITE_DENY;
					if (action === SQLite.SQLITE_FUNCTION && detail?.toLowerCase() === 'load_extension')
						return SQLite.SQLITE_DENY;
					return [
						SQLite.SQLITE_SELECT,
						SQLite.SQLITE_READ,
						SQLite.SQLITE_FUNCTION,
						SQLite.SQLITE_RECURSIVE
					].some((readAction) => readAction === action)
						? SQLite.SQLITE_OK
						: SQLite.SQLITE_DENY;
				},
				null
			);
			await db.transaction(async () => {
				const isNew = !(await db.all("SELECT name FROM sqlite_master WHERE type='table' LIMIT 1"))
					.length;
				await initCore(db);
				if (args.demo && isNew) await seedDemo();
				if (args.demo) await migrateDemo();
			});
			if (args.demo) await prepareLocalViews(db);
		} catch {
			if (connection !== undefined) await sqlite.close(connection);
			connection = undefined;
			throw new Error(
				'Could not open persistent OPFS storage. Check browser storage permissions and available space.'
			);
		}
		databaseName = name;
		channel = new BroadcastChannel(`life-ui:database:${name}`);
		channel.onmessage = () => respond({ changed: true });
		return snapshot();
	}
	if (method === 'close') {
		if (connection !== undefined) await sqlite.close(connection);
		connection = undefined;
		channel?.close();
		return null;
	}
	if (connection === undefined) throw new Error('Open a workspace first.');
	switch (method) {
		case 'snapshot':
			return snapshot();
		case 'rows':
			return (await local.rows(args.view)).map((row) => row.record);
		case 'search':
			return local.search(args);
		case 'listViews':
			return local.listViews(args);
		case 'saveView':
			return local.saveView(args);
		case 'deleteView':
			return local.deleteView(args);
		case 'options':
			return local.options(args);
		case 'write':
			return local.write(args);
		case 'writeability':
			return local.writeability(args);
		case 'sync': {
			if (databaseName === 'life-ui-demo')
				throw new Error('Demo workspaces cannot sync. Open your workspace first.');
			if (
				args.maxRows !== undefined &&
				(!Number.isSafeInteger(args.maxRows) || (args.maxRows as number) < 0)
			) {
				throw new Error('maxRows must be a nonnegative safe integer.');
			}
			if (args.tables !== undefined) {
				if (
					!args.tables ||
					typeof args.tables !== 'object' ||
					![Object.prototype, null].includes(Object.getPrototypeOf(args.tables)) ||
					Object.values(args.tables).some((value) => typeof value !== 'boolean')
				) {
					throw new Error('tables must be a plain object of boolean values.');
				}
				for (const table of Object.keys(args.tables)) qident(table);
			}
			const hub = createHttpHub(args.endpoint, args.token, (url, init) =>
				fetch(url, { ...init, signal: AbortSignal.timeout(120_000) })
			);
			const result = await createCoreHandlers(db, () => hub, 'life-ui').sync(args);
			await db.run("INSERT OR REPLACE INTO _core_state(key,value) VALUES ('skipped_tables',?)", [
				JSON.stringify(result.skipped)
			]);
			return result;
		}
		default:
			throw new Error('Unknown database operation.');
	}
}

scope.onmessage = ({ data }) => {
	// SQLite retries can yield, so even separate read requests must wait their turn.
	queue = queue.then(async () => {
		try {
			if (data?.contractHash !== CORE_CONTRACT_HASH)
				throw new Error('Core contract does not match the database worker. Reload the app.');
			if (
				!data ||
				typeof data.method !== 'string' ||
				!data.args ||
				typeof data.args !== 'object' ||
				Array.isArray(data.args)
			) {
				throw new Error('Invalid database request.');
			}
			if (!navigator.locks)
				throw new Error(
					'Web Locks are unavailable; this browser cannot safely open persistent storage.'
				);
			const name = databaseName ?? (data.args.demo === true ? 'life-ui-demo' : 'life-ui');
			const result = await navigator.locks.request(`life-ui:dispatch:${name}`, () =>
				dispatch(data as DatabaseRequest)
			);
			respond({ id: data.id, result });
			if (['write', 'sync', 'saveView', 'deleteView'].includes(data.method)) {
				channel?.postMessage({ changed: true });
				respond({ changed: true });
			}
		} catch (error) {
			const e = error as Error & { violations?: unknown };
			respond({
				id: data?.id,
				error: {
					name: e.name ?? 'Error',
					message: e.message ?? 'Database request failed.',
					...(e.violations ? { violations: e.violations } : {})
				}
			});
			// Sync commits individual pulls and receipts. Its final request can
			// fail after those changes. The caller owns its refresh/error; notify
			// the other tabs without racing that error with a second local refresh.
			if (data?.method === 'sync' && connection !== undefined) {
				channel?.postMessage({ changed: true });
			}
		}
	});
};
