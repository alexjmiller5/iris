import { expect } from 'bun:test';
import { Database } from 'bun:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { initCore } from 'iris-core/client';
import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
import { createWorkspaceControl } from '../apps/web/src/lib/workspace-control';
import type { PendingApproval } from '../apps/web/src/lib/governance/api';
import type { PendingChangeset } from '../apps/web/src/lib/governance/changeset-journal';
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const scope = { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'principal-1' };
const governance = {
	...scope,
	protocol: 'selected-inverse-proposals-v1',
	principal: { kind: 'user', principalId: scope.principalId },
	authority: { propose: true, approve: true },
	limits: {
		maxSelectedEvents: 100,
		maxChangedColumns: 64,
		maxRequestBytes: 65536,
		maxPageSize: 100,
		previewTtlSeconds: 300
	}
};
// Capabilities identify their principal through the canonical principal object, not a top-level field.
delete (governance as Partial<typeof governance>).principalId;
const changesets = {
	deploymentId: scope.deploymentId,
	sessionId: scope.sessionId,
	protocol: 'bounded-changeset-proposals-v1',
	principal: { kind: 'user', principalId: scope.principalId },
	authority: { propose: true, approve: true },
	limits: {
		maxOperations: 20,
		maxTables: 10,
		maxBytes: 65536,
		maxReadSets: 10,
		maxMembershipRows: 100,
		maxReadRows: 100,
		previewTtlSeconds: 300
	}
};
const approval: PendingApproval = {
	version: 1,
	scope,
	target: { table: 'items', rowId: 'row-1' },
	intent: { kind: 'selected_inverse', eventIds: ['event-1'] },
	revision: { updated_at: '2030-01-01T00:00:00.000Z', hub_at: null },
	changes: [
		{
			column: 'quantity',
			before: { type: 'integer', value: '9223372036854775807' },
			after: { type: 'null' }
		}
	],
	selectedEventIds: ['event-1'],
	request: {
		proposalId: 'proposal-1',
		expectedVersion: 'version-1',
		previewToken: 'synthetic-preview',
		idempotencyKey: 'uncertain-key'
	}
};
const change: PendingChangeset = {
	version: 1,
	scope: { ...scope, endpoint: 'https://example.test' },
	proposal: {
		id: 'proposal-1',
		version: 'version-1',
		state: 'pending',
		input: {
			operations: [
				{
					kind: 'create',
					table: 'items',
					id: 'row-1',
					expected_revision: null,
					values: { label: 'synthetic' }
				}
			],
			reads: []
		},
		changes: [
			{ table: 'items', id: 'row-1', kind: 'create', before: null, after: { label: 'synthetic' } }
		],
		dependencies: 'digest',
		proposedBy: { kind: 'agent', principalId: 'agent-1' },
		claimedOrigin: null,
		createdAt: '2030-01-01T00:00:00.000Z',
		updatedAt: '2030-01-01T00:00:00.000Z'
	},
	request: { ...approval.request }
};
function legacyJournals(
	options: {
		absent?: boolean;
		race?: boolean;
		invalidSchema?: boolean;
		versionChange?: boolean;
		key?: unknown;
	} = {}
) {
	const data = new Map<string, Array<{ key: unknown; value: unknown }>>([
		[
			'iris-governance',
			[
				{
					key: options.key ?? '["deployment-1","session-1","principal-1"]',
					value:
						'{"request":{"idempotencyKey":"uncertain-governance"},"integer":"9223372036854775807"}'
				},
				{ key: 'other-session', value: '{unreadable-but-retained' }
			]
		],
		[
			'iris-changesets',
			[
				{
					key: '["https://example.test","deployment-1","session-1","principal-1"]',
					value: '{"request":{"idempotencyKey":"uncertain-changeset"},"raw":"\\ud800"}'
				}
			]
		]
	]);
	const opened: string[] = [],
		modes: string[] = [];
	let closed = 0,
		aborted = 0;
	const factory = {
		databases: async () =>
			options.absent
				? [{ name: 'unrelated-db', version: 1 }]
				: [...data.keys()].map((name) => ({ name, version: 1 })),
		open: (name: string) => {
			opened.push(name);
			const db = {
				version: 1,
				objectStoreNames: { length: 1, contains: (store: string) => store === 'pending' },
				onversionchange: null as null | (() => void),
				close: () => closed++,
				transaction: (_store: string, mode: string) => {
					modes.push(mode);
					let index = 0,
						failed = false;
					const tx = {
						error: null,
						oncomplete: null as null | (() => void),
						onabort: null as null | (() => void),
						onerror: null,
						abort: () => {
							failed = true;
							aborted++;
							queueMicrotask(() => tx.onabort?.());
						},
						objectStore: () => ({
							keyPath: null,
							autoIncrement: options.invalidSchema ?? false,
							indexNames: { length: 0 },
							openCursor: () => {
								const request = {
									result: null as null | { key: unknown; value: unknown; continue: () => void },
									onsuccess: null as null | (() => void)
								};
								const emit = () => {
									if (failed) return;
									const row = data.get(name)![index++];
									if (options.versionChange && index === 1) {
										db.onversionchange?.();
										if (failed) return;
									}
									request.result = row
										? { ...structuredClone(row), continue: () => queueMicrotask(emit) }
										: null;
									request.onsuccess?.();
									if (!row && !failed) queueMicrotask(() => tx.oncomplete?.());
								};
								queueMicrotask(emit);
								return request;
							}
						})
					};
					return tx;
				}
			};
			let upgradeAborted = false;
			const request = {
				result: db,
				error: new Error('Listed legacy database disappeared'),
				transaction: {
					abort: () => {
						upgradeAborted = true;
						aborted++;
					}
				},
				onupgradeneeded: null as null | (() => void),
				onerror: null as null | (() => void),
				onblocked: null,
				onsuccess: null as null | (() => void)
			};
			queueMicrotask(() => {
				if (options.race) request.onupgradeneeded?.();
				if (upgradeAborted) request.onerror?.();
				else request.onsuccess?.();
			});
			return request;
		}
	};
	return {
		data,
		factory: factory as unknown as IDBFactory,
		opened,
		modes,
		get closed() {
			return closed;
		},
		get aborted() {
			return aborted;
		}
	};
}
function dir(name: string, entries: Map<string, unknown> = new Map()) {
	return {
		name,
		kind: 'directory' as const,
		entries,
		async *[Symbol.asyncIterator]() {
			yield* entries;
		}
	};
}
function blob(name: string, value: string) {
	return {
		name,
		kind: 'file' as const,
		getFile: async () => new File([value], name, { lastModified: 17 })
	};
}
export async function migrationHostFixture(
	createHost: typeof import('../apps/web/src/lib/workspace-migration-host').createWorkerMigrationHost
) {
	const flags = {
		failCopy: false,
		failRemove: false,
		lostAck: false,
		encrypted: true,
		corruptPending: false,
		retired: true
	};
	const scratch = mkdtempSync(join(tmpdir(), 'iris-migration-host-'));
	const sourcePath = join(scratch, 'source.sqlite'),
		targetPath = join(scratch, 'target.sqlite');
	let source: Database | undefined = new Database(sourcePath),
		target: Database | undefined;
	const getTarget = () => (target ??= new Database(targetPath));
	const driver = (read: () => Database) => ({
		all: async (sql: string) => read().query(sql).all() as Record<string, unknown>[],
		run: async (sql: string, params: unknown[] = []) =>
			read()
				.query(sql)
				.run(...(params as never[])).changes,
		transaction: async <T,>(work: () => Promise<T>) => {
			const db = read();
			db.exec('BEGIN');
			try {
				const value = await work();
				db.exec('COMMIT');
				return value;
			} catch (error) {
				db.exec('ROLLBACK');
				throw error;
			}
		}
	});
	const sourceDriver = driver(() => {
		if (!source) throw Error('Legacy SQLite is closed');
		return source;
	});
	await initCore(sourceDriver as never);
	source!.exec(
		"CREATE TABLE records(id TEXT PRIMARY KEY,amount INTEGER,payload BLOB);INSERT INTO records VALUES('row-1',9223372036854775807,x'00FF80');INSERT INTO _core_pending VALUES('records','row-1','dirty-local');INSERT INTO _core_history_hold VALUES('records','row-1','unsynced-history');INSERT OR REPLACE INTO _core_state(key,value) VALUES('hub','https://example.test')"
	);
	const journals = legacyJournals();
	journals.data.set('iris-governance', [
		{
			key: JSON.stringify([scope.deploymentId, scope.sessionId, scope.principalId]),
			value: JSON.stringify(approval)
		}
	]);
	journals.data.set('iris-changesets', [
		{
			key: JSON.stringify([
				'https://example.test',
				scope.deploymentId,
				scope.sessionId,
				scope.principalId
			]),
			value: JSON.stringify(change)
		}
	]);
	(journals.factory as unknown as { deleteDatabase(name: string): unknown }).deleteDatabase = (
		name
	) => {
		const request = { onsuccess: null as null | (() => void), onerror: null, onblocked: null };
		queueMicrotask(() => {
			journals.data.delete(name);
			request.onsuccess?.();
		});
		return request;
	};
	const root = dir(
		'',
		new Map<string, unknown>([
			['iris', { name: 'iris', kind: 'file' }],
			['encrypted-1', { name: 'encrypted-1', kind: 'file' }],
			[
				'iris-attachments',
				dir(
					'iris-attachments',
					new Map<string, unknown>([
						['empty', dir('empty')],
						['.stage-pending', blob('.stage-pending', '{"state":"uploading"}')],
						['orphan', dir('orphan', new Map([['bytes', blob('bytes', 'retained orphan')]]))]
					])
				)
			],
			[
				'backups',
				dir(
					'backups',
					new Map([
						[
							'staged',
							dir(
								'staged',
								new Map([['backup.sqlite', blob('backup.sqlite', 'synthetic staged backup')]])
							)
						]
					])
				)
			]
		])
	);
	const origin = Object.assign(root, {
		getDirectoryHandle: async (name: string, options?: { create?: boolean }) => {
			expect(options?.create).not.toBe(true);
			const value = root.entries.get(name) as { kind?: string } | undefined;
			if (!value) throw new DOMException('Missing', 'NotFoundError');
			if (value.kind !== 'directory') throw new DOMException('Wrong kind', 'TypeMismatchError');
			return value;
		},
		removeEntry: async (name: string) => {
			if (flags.failRemove) throw Error('Cleanup interrupted');
			if (!root.entries.delete(name)) throw new DOMException('Missing', 'NotFoundError');
		}
	});
	const storage = new Map([
		['iris:recents:workspace', '{retained malformed'],
		['unknown-preference', 'preserve exact']
	]);
	const storageBridge = {
		get length() {
			return storage.size;
		},
		key: (index: number) => [...storage.keys()][index] ?? null,
		getItem: (key: string) => storage.get(key) ?? null,
		removeItem: (key: string) => {
			storage.delete(key);
		}
	};
	let connection: { endpoint: string; token: string } | null = {
		endpoint: 'https://example.test',
		token: 'synthetic-consumer'
	};
	const resource = {
		root: new Uint8Array(32).fill(149),
		workspace: 'synthetic-host',
		generation: 1,
		connection: { endpoint: 'https://example.test', capabilities: { governance, changesets } }
	};
	const cells = new Map<string, EncryptedWorkspaceRecord>();
	const openStore = async (_workspace: string, key: string) => ({
		read: async () => structuredClone(cells.get(key) ?? null),
		compareAndSwap: async (
			before: EncryptedWorkspaceRecord | null,
			next: EncryptedWorkspaceRecord
		) => {
			if (JSON.stringify(before) !== JSON.stringify(cells.get(key) ?? null)) return false;
			cells.set(key, structuredClone(next));
			return true;
		},
		close() {}
	});
	const control = await createWorkspaceControl(
		resource.root,
		resource.workspace,
		await openStore(resource.workspace, 'control')
	);
	await control.initialize();
	const admission = createWorkspaceAdmission({ revisions: control, close: async () => {} });
	await admission.unlock(async () => resource);
	let copies = 0;
	const heldLocks = new Set<string>();
	let host: Awaited<ReturnType<typeof createHost>>;
	try {
		host = await createHost({
			admission,
			control: {
				readManifest: () => control.readManifest(),
				writeManifest: async (before, next) => {
					await control.writeManifest(before, next);
					if (flags.lostAck && next.phase === 'cleanup')
						throw Error('Publish acknowledgement lost');
				}
			},
			locks: {
				request: async (name: string, _options: unknown, work: () => Promise<unknown>) => {
					if (heldLocks.has(name)) throw Error('Fixture lock recursion');
					heldLocks.add(name);
					try {
						return await work();
					} finally {
						heldLocks.delete(name);
					}
				}
			} as unknown as LockManager,
			openStore,
			sourceId: 'legacy-iris',
			source: {
				root: origin as unknown as FileSystemDirectoryHandle,
				owners: [
					{ name: 'iris', kind: 'file', owner: 'sqlite' },
					{ name: 'encrypted-1', kind: 'file', owner: 'encrypted-sqlite' },
					{ name: 'iris-attachments', kind: 'directory', owner: 'files' },
					{ name: 'backups', kind: 'directory', owner: 'backups' }
				],
				journals: journals.factory,
				storage: storageBridge,
				readConnection: () => connection,
				clearConnection: async (expected) => {
					if (connection !== null && JSON.stringify(connection) !== JSON.stringify(expected))
						throw Error('Legacy credential changed');
					connection = null;
				},
				assertLegacyRetired: async () => {
					if (!flags.retired) throw Error('Legacy handles active');
				}
			},
			database: {
				source: sourceDriver,
				target: driver(getTarget),
				sourceFiles: ['iris'],
				targetFiles: ['encrypted-1'],
				assertTargetEncrypted: async () => {
					if (!flags.encrypted) throw Error('Target engine not keyed');
				},
				copyIntoTarget: async () => {
					copies++;
					expect(heldLocks.has('iris:dispatch:iris')).toBe(true);
					expect(heldLocks.has('iris:dispatch:encrypted-1')).toBe(true);
					if (flags.failCopy) throw Error('Native backup interrupted');
					target?.close();
					target = undefined;
					execFileSync(
						'python3',
						[
							'-c',
							'import sqlite3,sys\ns=sqlite3.connect(sys.argv[1]);t=sqlite3.connect(sys.argv[2]);s.backup(t,pages=64);t.close();s.close()',
							sourcePath,
							targetPath
						],
						{ timeout: 8000 }
					);
					if (flags.corruptPending) getTarget().exec('DELETE FROM _core_pending');
				},
				closeSource: async () => {
					source?.close();
					source = undefined;
				}
			},
			journalStore: async (key, codec) => ({
				load: async () => (cells.has(key) ? codec.decode(structuredClone(cells.get(key))) : null),
				retain: async (value) => {
					const next = codec.encode(value);
					if (cells.has(key) && !codec.equal(cells.get(key), next)) throw Error('Pending changed');
					cells.set(key, structuredClone(next) as EncryptedWorkspaceRecord);
				},
				resolve: async () => {
					throw Error('Fixture never resolves pending');
				},
				close() {}
			})
		});
	} catch (error) {
		await admission.close();
		control.close();
		resource.root.fill(0);
		source?.close();
		target?.close();
		rmSync(scratch, { recursive: true, force: true });
		throw error;
	}
	return {
		host,
		control,
		flags,
		root,
		journalData: journals.data,
		storage,
		backups: () => copies,
		target: getTarget,
		close: async () => {
			host.close();
			await admission.close();
			control.close();
			resource.root.fill(0);
			source?.close();
			target?.close();
			rmSync(scratch, { recursive: true, force: true });
		}
	};
}
