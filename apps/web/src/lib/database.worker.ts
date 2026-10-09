/// <reference lib="webworker" />
import { prepareLocalCatalog } from '../../../../scripts/local-catalog';
import { enrollmentEndpoint } from './enrollment-binding';
import { rejectionSnapshot } from './rejection-inbox';
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
	syncStatus,
	type BackupFiles,
	type Row,
	type SqlDriver,
	type SqlReadStatement,
	type SqlReadContext,
	type Value
} from 'iris-core/client';
import { prepareLocalViews, prepareLocalPins } from '../../../../scripts/local-views';
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
let readingInventory = false;
let dependencyReads: { name: string | null; database: string | null }[] | undefined;
// SQLite identifiers fold ASCII only; Unicode case pairs can name different tables.
const sqliteName = (name: string) => name.replace(/[A-Z]/g, (letter) => letter.toLowerCase());

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
	async readDependencies(statements: readonly SqlReadStatement[], context: SqlReadContext) {
		if (connection === undefined) throw new Error('Open a workspace first.');
		if (
			!Array.isArray(statements) ||
			statements.some((entry) => typeof entry?.sql !== 'string') ||
			!Array.isArray(context?.ownedTempTables) ||
			context.ownedTempTables.some((name) => typeof name !== 'string')
		)
			throw new Error('Invalid SQL dependency inspection.');
		// Inventory is fixed host SQL. These additional PRAGMAs are not available
		// through catalog reads; no validation query is stepped during discovery.
		let databases: Row[];
		let inventory: Row[];
		readingInventory = true;
		try {
			databases = await db.all('PRAGMA database_list');
			inventory = await db.all('PRAGMA table_list');
		} finally {
			readingInventory = false;
		}
		if (databases.some((row) => row.name !== 'main' && row.name !== 'temp')) return null;
		const owned = new Set(context.ownedTempTables.map(sqliteName));
		const temporary = inventory.filter(
			(row) => row.schema === 'temp' && row.name !== 'sqlite_temp_schema'
		);
		if (
			temporary.some((row) => row.type !== 'table' || !owned.has(sqliteName(String(row.name)))) ||
			[...owned].some((name) => !temporary.some((row) => sqliteName(String(row.name)) === name))
		)
			return null;
		const objects = new Map(
			inventory
				.filter((row) => row.schema === 'main')
				.map((row) => [sqliteName(String(row.name)), row])
		);
		if ([...owned].some((name) => objects.has(name))) return null;
		const reads: { name: string | null; database: string | null }[] = [];
		dependencyReads = reads;
		reading = true;
		try {
			for (const entry of statements) {
				const prepared: number[] = [];
				try {
					for await (const statement of sqlite.statements(connection, entry.sql, {
						unscoped: true
					})) {
						prepared.push(statement);
						if (prepared.length > 1) throw new Error('Expected one read-only SQL statement.');
					}
					if (prepared.length !== 1 || !statementReadOnly(prepared[0]))
						throw new Error('Expected one read-only SQL statement.');
					sqlite.bind_collection(prepared[0], entry.params ?? []);
				} finally {
					for (const statement of prepared) await sqlite.finalize(statement);
				}
			}
		} finally {
			dependencyReads = undefined;
			reading = false;
		}
		const tables = new Set<string>();
		for (const read of reads) {
			if (!read.name) return null;
			const name = sqliteName(read.name);
			if ((!read.database || read.database === 'temp') && owned.has(name)) continue;
			if (read.database && read.database !== 'main') return null;
			const object = objects.get(name);
			// Columnless reads of the engine's CTEs may have no database qualifier.
			// A real schema object always wins; TEMP ownership is asserted by core.
			if (
				!read.database &&
				!object &&
				owned.has('_core_write_before') &&
				['changed', 'before', 'now'].includes(name)
			)
				continue;
			if (!object && ['json_each', 'json_tree'].includes(name)) continue;
			if (!object || /^(sqlite_|_)/i.test(name)) return null;
			if (object.type === 'view') continue; // SQLite also reports the underlying reads.
			if (object.type !== 'table') return null;
			tables.add(String(object.name));
		}
		return { tables: [...tables].sort() };
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

let vfsName = '';
/** Opens the named OPFS database with the read-only-statement authorizer. */
async function connect(name: string) {
	connection = await sqlite.open_v2(name, undefined, vfsName);
	sqlite.set_authorizer(
		connection,
		(_, action, name, detail, database) => {
			if (dependencyReads && action === SQLite.SQLITE_READ)
				dependencyReads.push({ name, database });
			if (!reading) return SQLite.SQLITE_OK;
			// The authorizer runs during preparation too: reject connection control
			// and mutating PRAGMAs before they can act. FTS5 reads data_version on reopen.
			if (action === SQLite.SQLITE_PRAGMA)
				return ['table_info', 'table_xinfo', 'foreign_key_list', 'data_version'].includes(
					name?.toLowerCase() ?? ''
				) ||
					(readingInventory && ['database_list', 'table_list'].includes(name?.toLowerCase() ?? ''))
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
}

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
		catalog: await local.catalog({}),
		status,
		undo: (await local.undoStatus({})).action,
		lastSync: status.lastSuccessfulSync,
		skipped: status.skippedTables,
		rejected: await rejectionSnapshot(() => local.rejections({ limit: 100, offset: 0 }))
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

// Backup files live in OPFS under backups/<staged|recovery|exports>/<name>;
// core receives only these references and never sees OPFS itself.
const BACKUP_REF = /^(staged|recovery|exports)\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
async function backupDirectory(kind: string) {
	const root = await navigator.storage.getDirectory();
	const backups = await root.getDirectoryHandle('backups', { create: true });
	return backups.getDirectoryHandle(kind, { create: true });
}
async function backupHandle(ref: string, create = false) {
	if (!BACKUP_REF.test(ref)) throw new Error('Invalid backup file reference.');
	const [kind, name] = ref.split('/');
	return (await backupDirectory(kind)).getFileHandle(name, { create });
}
const stamp = () => new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
// Long backup actions report progress; the page folds it into the sync pill.
let progressPhase = '';
let progressAt = 0;
function progress(done: number, total: number) {
	const now = Date.now();
	if (now - progressAt < 250 && done < total) return;
	progressAt = now;
	respond({ progress: { phase: progressPhase, done, total } });
}
const writers = new Set<FileSystemSyncAccessHandle>();
const files: BackupFiles = {
	open(ref) {
		let reader: ReadableStreamDefaultReader<string> | undefined;
		return {
			async read() {
				if (!reader) {
					const file = await (await backupHandle(ref)).getFile();
					const head = new Uint8Array(await file.slice(0, 2).arrayBuffer());
					let done = 0;
					let stream: ReadableStream<BufferSource> = file.stream().pipeThrough(
						new TransformStream<Uint8Array<ArrayBuffer>, BufferSource>({
							transform(chunk, out) {
								progress((done += chunk.length), file.size);
								out.enqueue(chunk);
							}
						})
					);
					// gzip's trailer CRC and length make a damaged copy fail here.
					if (head[0] === 0x1f && head[1] === 0x8b)
						stream = stream.pipeThrough(new DecompressionStream('gzip'));
					reader = stream.pipeThrough(new TextDecoderStream('utf-8', { fatal: true })).getReader();
				}
				const { done, value } = await reader.read();
				return done ? null : value;
			}
		};
	},
	create(ref) {
		let handle: FileSystemSyncAccessHandle | undefined;
		let at = 0;
		const encoder = new TextEncoder();
		return {
			async write(text) {
				if (!handle) {
					handle = await (await backupHandle(ref, true)).createSyncAccessHandle();
					writers.add(handle);
					handle.truncate(0);
				}
				at += handle.write(encoder.encode(text), { at });
				progress(at, 0);
			},
			async close() {
				if (!handle) return;
				handle.flush();
				handle.close();
				writers.delete(handle);
			}
		};
	}
};
/** Closes writers an aborted export or restore left open, then removes its partial file. */
async function abandon(ref: string) {
	for (const handle of writers) handle.close();
	writers.clear();
	const [kind, name] = ref.split('/');
	await (await backupDirectory(kind)).removeEntry(name).catch(() => {});
}
async function backupFiles(kind: string) {
	const out: { file: string; bytes: number; modified: number }[] = [];
	for await (const [name, handle] of (await backupDirectory(kind)) as unknown as AsyncIterable<
		[string, FileSystemHandle]
	>) {
		if (handle.kind !== 'file') continue;
		const file = await (handle as FileSystemFileHandle).getFile();
		out.push({ file: `${kind}/${name}`, bytes: file.size, modified: file.lastModified });
	}
	return out.sort((a, b) => b.modified - a.modified);
}
/** Streams bytes into a backup file through a sync handle, the OPFS API every
 * browser that can open the workspace also supports. */
async function copyInto(ref: string, stream: ReadableStream<Uint8Array>) {
	const handle = await (await backupHandle(ref, true)).createSyncAccessHandle();
	try {
		handle.truncate(0);
		let at = 0;
		for await (const chunk of stream as unknown as AsyncIterable<Uint8Array>)
			at += handle.write(chunk, { at });
		handle.flush();
	} finally {
		handle.close();
	}
}
async function hubFor(args: { endpoint: string; token: string }, timeout: number) {
	if (databaseName === 'iris-demo') throw new Error('Sample workspaces have no hub.');
	return createHttpHub(args.endpoint, args.token, (url, init) =>
		fetch(url, { ...init, signal: AbortSignal.timeout(timeout) })
	);
}

const local = createCoreHandlers(
	db,
	() => {
		throw new Error('No hub connection.');
	},
	'iris',
	null,
	files
);

async function dispatch(request: DatabaseRequest) {
	const { method, args } = request;
	if (method === 'open') {
		if (args.demo !== undefined && typeof args.demo !== 'boolean')
			throw new Error('demo must be a boolean.');
		const name = args.demo ? 'iris-demo' : 'iris';
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
			const vfs = await OPFSCoopSyncVFS.create('iris', module);
			sqlite.vfs_register(vfs, true);
			vfsName = vfs.name;
			await connect(name);
			await db.transaction(async () => {
				const isNew = !(await db.all("SELECT name FROM sqlite_master WHERE type='table' LIMIT 1"))
					.length;
				await initCore(db);
				if (args.demo && isNew) await seedDemo();
				if (args.demo) await migrateDemo();
			});
			if (args.demo) {
				await prepareLocalCatalog(db);
				await prepareLocalViews(db);
				await prepareLocalPins(db);
			}
		} catch {
			if (connection !== undefined) await sqlite.close(connection);
			connection = undefined;
			throw new Error(
				'Could not open persistent OPFS storage. Check browser storage permissions and available space.'
			);
		}
		databaseName = name;
		channel = new BroadcastChannel(`iris:database:${name}`);
		channel.onmessage = ({ data }) => respond({ changed: data?.changed ?? true });
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
		case 'enrollmentEndpoint':
			return enrollmentEndpoint(db, createHttpHub(args.endpoint, 'endpoint-check', fetch).endpoint);
		case 'enrollmentApproval':
			return local.enrollmentApproval(args);
		case 'validateDeviceSession':
			return local.validateDeviceSession(args);
		case 'enrollmentPollResult':
			return local.enrollmentPollResult(args);
		case 'sessionRevocationResult':
			return local.sessionRevocationResult(args);

		case 'snapshot':
			return snapshot();
		case 'rejections':
			return local.rejections(args);
		case 'rows':
			return (await local.rows(args.view)).map((row) => row.record);
		case 'referenceSources':
			return local.referenceSources(args);
		case 'referencedBy':
			return local.referencedBy(args);
		case 'resolveSourceLink':
			return local.resolveSourceLink(args);
		case 'search':
			return local.search(args);
		case 'mentionedBy':
			return local.mentionedBy(args);
		case 'mentionLabels':
			return local.mentionLabels(args);
		case 'viewEmbed':
			return local.viewEmbed(args);
		case 'remoteRows': {
			if (databaseName === 'iris-demo') throw new Error('Sample workspaces cannot browse a hub.');
			const { token, ...input } = args;
			const hub = createHttpHub(input.endpoint, token, (url, init) =>
				fetch(url, { ...init, signal: AbortSignal.timeout(30_000) })
			);
			return createCoreHandlers(db, () => hub, 'iris').remoteRows(input);
		}
		case 'remoteRow': {
			if (databaseName === 'iris-demo') throw new Error('Sample workspaces cannot browse a hub.');
			const { token, ...input } = args;
			const hub = createHttpHub(input.endpoint, token, (url, init) =>
				fetch(url, { ...init, signal: AbortSignal.timeout(30_000) })
			);
			return createCoreHandlers(db, () => hub, 'iris').remoteRow(input);
		}
		case 'replicaFile': {
			// The VFS holds the database file open; close it, copy the exact bytes
			// to a separate file the page can download, then reopen.
			const name = databaseName!;
			const ref = `exports/${name}-${stamp()}.sqlite`;
			await sqlite.close(connection);
			connection = undefined;
			try {
				const root = await navigator.storage.getDirectory();
				const source = await (await root.getFileHandle(name)).getFile();
				await copyInto(ref, source.stream());
			} catch {
				await abandon(ref);
				throw new Error('Could not copy the database. Close other Iris tabs and try again.');
			} finally {
				await connect(name);
			}
			return (await backupHandle(ref)).getFile();
		}
		case 'exportReplica': {
			const ref = `exports/${databaseName}-${stamp()}.sql`;
			progressPhase = 'Exporting';
			try {
				const summary = await local.exportReplica({ file: ref });
				return { file: await (await backupHandle(ref)).getFile(), summary };
			} catch (error) {
				await abandon(ref);
				throw error;
			}
		}
		case 'stageBackup': {
			if (!(args.blob instanceof Blob)) throw new Error('Choose a backup file.');
			for (const old of await backupFiles('staged'))
				await (await backupDirectory('staged')).removeEntry(old.file.split('/')[1]);
			const ref = `staged/${stamp()}-${args.name.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80)}`;
			await copyInto(ref, args.blob.stream());
			return ref;
		}
		case 'previewRestore':
			progressPhase = 'Checking backup';
			return local.previewRestore(args);
		case 'restoreReplica': {
			const recovery = `recovery/${databaseName}-before-restore-${stamp()}.sql`;
			let opens = 0;
			const open = files.open;
			// Core reads the backup twice: once to validate, once to apply.
			files.open = (ref) => {
				progressPhase = ++opens === 1 ? 'Checking backup' : 'Restoring';
				return open(ref);
			};
			progressPhase = 'Checking backup';
			try {
				const create = files.create;
				files.create = (ref) => {
					progressPhase = 'Saving recovery copy';
					return create(ref);
				};
				try {
					const result = await local.restoreReplica({ ...args, recovery });
					// Keep the three newest recovery copies.
					for (const old of (await backupFiles('recovery')).slice(3))
						await (await backupDirectory('recovery')).removeEntry(old.file.split('/')[1]);
					return { ...result, recoveryFile: recovery };
				} finally {
					files.create = create;
				}
			} catch (error) {
				for (const handle of writers) handle.close();
				writers.clear();
				throw error;
			} finally {
				files.open = open;
			}
		}
		case 'recoveryBackups':
			return backupFiles('recovery');
		case 'backupFile':
			return (await backupHandle(args.file)).getFile();
		case 'hubBackups': {
			const hub = await hubFor(args, 30_000);
			return createCoreHandlers(db, () => hub, 'iris').hubBackups({ endpoint: args.endpoint });
		}
		case 'createHubBackup': {
			// The hub exports its whole database first; that takes about a minute.
			const hub = await hubFor(args, 600_000);
			return createCoreHandlers(db, () => hub, 'iris').createHubBackup({
				endpoint: args.endpoint
			});
		}
		case 'listSidebarPins':
			return local.listSidebarPins(args);
		case 'pinTable':
			return local.pinTable(args);
		case 'unpinTable':
			return local.unpinTable(args);
		case 'moveTablePin':
			return local.moveTablePin(args);
		case 'resolveDerived': {
			if (databaseName === 'iris-demo')
				throw new Error('Connect a workspace to resolve derived fields.');
			const { token, ...input } = args;
			const hub = createHttpHub(input.endpoint, token, (url, init) =>
				fetch(url, { ...init, signal: AbortSignal.timeout(90_000) })
			);
			return createCoreHandlers(db, () => hub, 'iris').resolveDerived(input);
		}
		case 'resolveViewDefinition':
			return local.resolveViewDefinition(args);
		case 'listViews':
			return local.listViews(args);
		case 'getRelatedViewDefault':
			return local.getRelatedViewDefault(args);
		case 'setRelatedViewDefault':
			return local.setRelatedViewDefault(args);
		case 'getViewDefault':
			return local.getViewDefault(args);
		case 'ensureDefaultView':
			return local.ensureDefaultView(args);
		case 'setViewDefault':
			return local.setViewDefault(args);
		case 'saveCatalogProperty':
			return local.saveCatalogProperty(args);
		case 'saveCatalogRule':
			return local.saveCatalogRule(args);
		case 'saveView':
			return local.saveView(args);
		case 'deleteView':
			return local.deleteView(args);
		case 'options':
			return local.options(args);
		case 'runRowAction':
			return local.runRowAction(args);
		case 'write':
			return local.write(args);
		case 'undo':
			return local.undo(args);
		case 'undoStatus':
			return local.undoStatus(args);
		case 'status':
			return syncStatus(db);
		case 'writeability':
			return local.writeability(args);
		case 'sync': {
			if (databaseName === 'iris-demo')
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
			return createCoreHandlers(db, () => hub, 'iris').sync(args);
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
			const name = databaseName ?? (data.args.demo === true ? 'iris-demo' : 'iris');
			const result = await navigator.locks.request(`iris:dispatch:${name}`, () =>
				dispatch(data as DatabaseRequest)
			);
			respond({ id: data.id, result });
			// Background sync polls every few seconds; only a sync that moved data refreshes views.
			const synced = result as { pulled?: number; pushed?: number; rejected?: unknown[] };
			if (
				(data.method !== 'sync' ||
					!!synced.pulled ||
					!!synced.pushed ||
					!!synced.rejected?.length) &&
				[
					'write',
					'runRowAction',
					'undo',
					'sync',
					'saveView',
					'deleteView',
					'setViewDefault',
					'setRelatedViewDefault',
					'saveCatalogProperty',
					'saveCatalogRule',
					'pinTable',
					'unpinTable',
					'moveTablePin',
					'restoreReplica'
				].includes(data.method)
			) {
				channel?.postMessage({ changed: data.method });
				respond({ changed: data.method });
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
				channel?.postMessage({ changed: 'sync' });
			}
		}
	});
};
