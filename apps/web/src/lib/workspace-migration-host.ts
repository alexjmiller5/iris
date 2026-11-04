import { collectWorkspaceSourceInventory } from './workspace-inventory-source';
import { collectSQLiteInventory, type SQLiteInventoryDriver } from './workspace-sqlite-inventory';
import { collectLegacyJournalInventory } from './workspace-legacy-journals';
import {
	collectWebStorageInventory,
	collectConsumerCredentialInventory
} from './workspace-auxiliary-inventory';
import {
	createWorkerEncryptedCell,
	createWorkerCredentialStore,
	createWorkerWebStorageStore
} from './workspace-host-cell';
import { createWorkerFileTree } from './workspace-file-tree';
import { createWorkerFileStore } from './workspace-file-store';
import { createWorkerJournalHost } from './governance/worker-journal';
import { changesetScopeKey } from './governance/changeset-journal';
import { assertMigrationPreserved, type WorkspaceMigrationSnapshot } from './workspace-migration';
import type {
	WorkspaceMigrationHost,
	WorkspaceMigrationManifest
} from './workspace-migration-runner';
import type { createWorkspaceControl } from './workspace-control';
import type { HubConnection } from './device-enrollment';
type Source = Parameters<typeof collectWorkspaceSourceInventory>[0];
type Options = {
	admission: Parameters<typeof createWorkerJournalHost>[0]['admission'];
	openStore: Parameters<typeof createWorkerEncryptedCell>[0]['openStore'];
	control: Pick<
		Awaited<ReturnType<typeof createWorkspaceControl>>,
		'readManifest' | 'writeManifest'
	>;
	locks?: Pick<LockManager, 'request'>;
	sourceId: string;
	source: Omit<Source, 'sqlite' | 'storage'> & {
		storage: Source['storage'] & Pick<Storage, 'removeItem'>;
		clearConnection(expected: Readonly<HubConnection> | null): Promise<void>;
	};
	database: {
		source: SQLiteInventoryDriver;
		target: SQLiteInventoryDriver;
		/** Concrete worker-engine binding to SQLite's backup API into an already keyed
		 * target. Never SQL export, raw file copy or source rekey. Requires exact MC/VFS
		 * runtime acceptance separately; the production vendor is not promoted here. */
		copyIntoTarget(): Promise<void>;
		assertTargetEncrypted(): Promise<void>;
		closeSource(): Promise<void>;
		/** First entry is the engine main filename, followed by its known sidecars. */
		sourceFiles: readonly string[];
		targetFiles: readonly string[];
	};
	journalStore?: Parameters<typeof createWorkerJournalHost>[0]['openStore'];
};
const domains = [
	'database-schema',
	'database-values',
	'pending-intents',
	'governance-journal',
	'changeset-journal',
	'files',
	'backups',
	'recents',
	'preferences',
	'credential'
] as const;
const encoder = new TextEncoder(),
	decoder = new TextDecoder('utf-8', { fatal: true });
const unavailable = () => new Error('Workspace migration storage is unavailable.');
const same = (a: Uint8Array, b: Uint8Array) =>
	a.length === b.length && a.every((v, i) => v === b[i]);
const safeName = (name: unknown): name is string =>
	typeof name === 'string' &&
	name.length > 0 &&
	name.length <= 4096 &&
	name !== '.' &&
	name !== '..' &&
	!name.includes('/') &&
	!name.includes('\0');
const empty = () =>
	Object.fromEntries(domains.map((key) => [key, []])) as WorkspaceMigrationSnapshot;
function wipe(value: WorkspaceMigrationSnapshot) {
	for (const rows of Object.values(value)) for (const row of rows) row.value.fill(0);
}
function encode(value: WorkspaceMigrationSnapshot) {
	assertMigrationPreserved(value, value);
	// Bound before outer JSON expansion; refuse rather than truncate large proof.
	let budget = 0;
	for (const rows of Object.values(value))
		for (const row of rows) {
			budget += 6 * (row.value.length + encoder.encode(row.key).length) + 16;
			if (budget > 16 * 1024 * 1024) throw new Error('Migration proof requires a streaming store.');
		}
	return encoder.encode(
		JSON.stringify(
			Object.fromEntries(
				domains.map((key) => [
					key,
					value[key].map((row) => {
						const text = decoder.decode(row.value);
						if (!same(encoder.encode(text), row.value)) throw unavailable();
						return [row.key, text];
					})
				])
			)
		)
	);
}
function decode(raw: Uint8Array) {
	const value: unknown = JSON.parse(decoder.decode(raw));
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).length !== domains.length
	)
		throw unavailable();
	const result = empty();
	try {
		for (const domain of domains) {
			const rows = (value as Record<string, unknown>)[domain];
			if (!Array.isArray(rows) || rows.length > 100000) throw unavailable();
			result[domain] = rows.map((row) => {
				if (
					!Array.isArray(row) ||
					row.length !== 2 ||
					typeof row[0] !== 'string' ||
					typeof row[1] !== 'string'
				)
					throw unavailable();
				return { key: row[0], value: encoder.encode(row[1]) };
			});
		}
		assertMigrationPreserved(result, result);
		return result;
	} catch (error) {
		wipe(result);
		throw error;
	}
}
function storageMap(value: Pick<WorkspaceMigrationSnapshot, 'recents' | 'preferences'>) {
	const map = new Map<string, string>();
	for (const row of [...value.recents, ...value.preferences]) {
		const key = JSON.parse(row.key),
			text = JSON.parse(decoder.decode(row.value));
		if (
			!Array.isArray(key) ||
			key.length !== 2 ||
			key[0] !== 'localStorage' ||
			typeof key[1] !== 'string' ||
			typeof text !== 'string' ||
			map.has(key[1])
		)
			throw unavailable();
		map.set(key[1], text);
	}
	return map;
}
function asStorage(map: Map<string, string>) {
	return {
		get length() {
			return map.size;
		},
		key: (index: number) => [...map.keys()][index] ?? null,
		getItem: (key: string) => map.get(key) ?? null
	};
}
const rootNames = { files: 'iris-attachments', backups: 'backups' } as const;
/** One worker-owned adapter for the existing migration runner. Not installed in
 * database.worker or UI. All side effects require its exclusive lock, original
 * unlock epoch, real legacy retirement and authenticated durable cleanup phase.
 * A native-backup synthetic fixture does not prove encrypted MC/OPFS copying.
 */
export async function createWorkerMigrationHost(
	options: Options
): Promise<WorkspaceMigrationHost & { close(): void }> {
	const { admission, openStore, control, sourceId, journalStore } = options;
	const locks = options.locks ?? globalThis.navigator?.locks;
	if (
		!locks ||
		typeof locks.request !== 'function' ||
		typeof sourceId !== 'string' ||
		!sourceId.length ||
		sourceId.length > 128
	)
		throw unavailable();
	const source = {
			...options.source,
			readConnection: options.source.readConnection.bind(options.source),
			assertLegacyRetired: options.source.assertLegacyRetired.bind(options.source),
			clearConnection: options.source.clearConnection.bind(options.source),
			owners: options.source.owners.map((entry) => ({ ...entry }))
		},
		database = {
			...options.database,
			copyIntoTarget: options.database.copyIntoTarget.bind(options.database),
			assertTargetEncrypted: options.database.assertTargetEncrypted.bind(options.database),
			closeSource: options.database.closeSource.bind(options.database),
			sourceFiles: [...options.database.sourceFiles],
			targetFiles: [...options.database.targetFiles]
		};
	const owner = await admission.run(async (resource, signal) => ({
		workspace: resource.workspace,
		generation: resource.generation,
		signal
	}));
	source.signal = source.signal ? AbortSignal.any([source.signal, owner.signal]) : owner.signal;
	const targetId = String(owner.generation),
		legacyNames = new Set([...database.sourceFiles, ...Object.values(rootNames)]),
		allNames = new Set([...legacyNames, ...database.targetFiles]);
	if (
		!database.sourceFiles.length ||
		!database.targetFiles.length ||
		database.targetFiles.some((name) => legacyNames.has(name)) ||
		new Set(database.targetFiles).size !== database.targetFiles.length ||
		[...allNames].some((name) => !safeName(name)) ||
		database.sourceFiles.some(
			(name) =>
				database.targetFiles.includes(name) || Object.values(rootNames).includes(name as never)
		) ||
		new Set(database.sourceFiles).size !== database.sourceFiles.length ||
		source.owners.some((entry) => !allNames.has(entry.name))
	)
		throw unavailable();
	const disposers: Array<() => void> = [];
	let disposed = false;
	function disposeAll() {
		if (disposed) return;
		disposed = true;
		let failed = false;
		for (const dispose of [...disposers].reverse())
			try {
				dispose();
			} catch {
				failed = true;
			}
		if (failed) throw new Error('Migration host cleanup failed.');
	}
	try {
		const proofCell = await createWorkerEncryptedCell({
			admission,
			openStore,
			purpose: 'metadata',
			context: { store: 'migration-source-proof', id: sourceId }
		});
		disposers.push(() => proofCell.close());
		const credentials = await createWorkerCredentialStore({ admission, openStore });
		disposers.push(() => credentials.close());
		const preferences = await createWorkerWebStorageStore({ admission, openStore });
		disposers.push(() => preferences.close());
		const files = await createWorkerFileTree({ admission, openStore, domain: 'files' });
		disposers.push(() => files.close());
		const backups = await createWorkerFileTree({ admission, openStore, domain: 'backups' });
		disposers.push(() => backups.close());
		const trees = { files, backups };
		const journal = createWorkerJournalHost({
			admission,
			...(journalStore ? { openStore: journalStore } : {})
		});
		disposers.push(() => journal.close());
		let closed = false,
			leased = false;
		async function guard() {
			if (closed || !leased) throw unavailable();
			source.signal?.throwIfAborted();
			await admission.run(async (resource, signal) => {
				if (
					signal !== owner.signal ||
					resource.workspace !== owner.workspace ||
					resource.generation !== owner.generation
				)
					throw unavailable();
				signal.throwIfAborted();
			});
		}
		function bound(manifest: WorkspaceMigrationManifest) {
			if (
				manifest.workspace !== owner.workspace ||
				manifest.source !== sourceId ||
				manifest.target !== targetId
			)
				throw unavailable();
		}
		async function proof() {
			await guard();
			const raw = await proofCell.read();
			if (!raw) throw unavailable();
			try {
				return decode(raw);
			} finally {
				raw.fill(0);
			}
		}
		async function directory(domain: keyof typeof trees) {
			await guard();
			try {
				return await source.root.getDirectoryHandle(rootNames[domain], { create: false });
			} catch (error) {
				if (error instanceof DOMException && error.name === 'NotFoundError') return null;
				throw error;
			}
		}
		async function names() {
			await guard();
			for await (const [name] of source.root as unknown as AsyncIterable<
				[string, FileSystemHandle]
			>)
				if (!allNames.has(name)) throw unavailable();
			const allowed = new Set([
				'iris-governance',
				'iris-changesets',
				`iris-vault-${owner.workspace}-${owner.generation}`,
				`iris-control-${owner.workspace}`
			]);
			for (const db of await source.journals.databases())
				if (!db.name || !allowed.has(db.name)) throw unavailable();
			await guard();
		}
		async function pending(value: WorkspaceMigrationSnapshot, retain: boolean) {
			for (const [kind, domain, name] of [
				['governance', 'governance-journal', 'iris-governance'],
				['changesets', 'changeset-journal', 'iris-changesets']
			] as const) {
				for (const row of value[domain]) {
					const key = JSON.parse(row.key);
					if (Array.isArray(key) && key.length === 2 && key[0] === name && key[1] === 'schema')
						continue;
					if (
						!Array.isArray(key) ||
						key.length !== 3 ||
						key[0] !== name ||
						key[1] !== 'pending' ||
						typeof key[2] !== 'string'
					)
						throw unavailable();
					const raw: unknown = JSON.parse(decoder.decode(row.value));
					if (typeof raw !== 'string') throw unavailable();
					const entry = JSON.parse(raw);
					const expected =
						kind === 'governance'
							? JSON.stringify([
									entry?.scope?.deploymentId,
									entry?.scope?.sessionId,
									entry?.scope?.principalId
								])
							: changesetScopeKey(entry.scope);
					if (key[2] !== expected) throw new Error('Legacy pending journal scope is unmapped.');
					if (kind === 'governance') {
						const hub = await database.target.all(
							"SELECT value FROM main._core_state WHERE key='hub'"
						);
						const credential = await credentials.read();
						await admission.run(async (resource) => {
							if (
								hub.length !== 1 ||
								typeof hub[0].value !== 'string' ||
								hub[0].value !== resource.connection.endpoint ||
								credential?.endpoint !== resource.connection.endpoint
							)
								throw new Error('Legacy governance endpoint is not established.');
						});
					}
					const handle = await journal.request({ method: 'open', kind });
					if (typeof handle !== 'string') throw unavailable();
					try {
						if (retain) await journal.request({ method: 'retain', handle, entry });
						const restored = await journal.request({ method: 'load', handle });
						if (JSON.stringify(restored) !== JSON.stringify(entry))
							throw new Error('Pending request restoration differs.');
					} finally {
						await journal.request({ method: 'close', handle });
					}
				}
			}
		}
		async function targetFiles(domain: keyof typeof trees) {
			const tree = trees[domain],
				index = await tree.metadata();
			if (!index) throw unavailable();
			const rows: WorkspaceMigrationSnapshot['files'] = [
				{
					key: JSON.stringify(['root']),
					value: encoder.encode(JSON.stringify({ exists: index.exists }))
				}
			];
			for (const path of index.directories)
				rows.push({
					key: JSON.stringify(['directory', ...path]),
					value: encoder.encode(JSON.stringify({ kind: 'directory' }))
				});
			for (const entry of index.files) {
				await guard();
				const file = await createWorkerFileStore({
					admission,
					openStore,
					domain,
					id: entry.object
				});
				let contents: Uint8Array<ArrayBuffer> | undefined;
				try {
					const metadata = await file.metadata();
					if (
						!metadata ||
						metadata.revision !== entry.revision ||
						metadata.size > 128 * 1024 * 1024
					)
						throw new Error('Target file inventory requires a streaming hash.');
					contents = new Uint8Array(metadata.size);
					let offset = 0;
					for await (const chunk of file.read()) {
						try {
							if (offset + chunk.length > contents.length) throw unavailable();
							contents.set(chunk, offset);
							offset += chunk.length;
						} finally {
							chunk.fill(0);
						}
					}
					if (offset !== contents.length) throw unavailable();
					const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', contents));
					await guard();
					rows.push({
						key: JSON.stringify(['file', ...entry.path]),
						value: encoder.encode(
							JSON.stringify({
								bytes: metadata.size,
								modified: metadata.lastModified,
								mime: metadata.type,
								sha256: Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('')
							})
						)
					});
				} finally {
					contents?.fill(0);
					file.close();
				}
			}
			if ((await tree.metadata())?.revision !== index.revision) throw unavailable();
			return rows.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
		}
		const host: WorkspaceMigrationHost & { close(): void } = {
			async exclusive(work) {
				if (closed) throw unavailable();
				return locks.request(
					`iris:migration:${owner.workspace}`,
					{ mode: 'exclusive', signal: source.signal },
					async () => {
						if (closed || leased) throw unavailable();
						leased = true;
						try {
							await guard();
							// Match the existing worker dispatch ABI while old handles retire.
							return await locks.request(
								`iris:dispatch:${database.sourceFiles[0]}`,
								{ mode: 'exclusive', signal: source.signal },
								() =>
									locks.request(
										`iris:dispatch:${database.targetFiles[0]}`,
										{ mode: 'exclusive', signal: source.signal },
										async () => {
											await guard();
											const result = await work();
											await guard();
											return result;
										}
									)
							);
						} finally {
							leased = false;
						}
					}
				);
			},
			async readManifest() {
				await guard();
				const value = await control.readManifest();
				if (value) bound(value);
				return value;
			},
			async writeManifest(before, next) {
				await guard();
				bound(next);
				if (before) bound(before);
				await control.writeManifest(before, next);
				await guard();
			},
			async assertLegacyRetired() {
				await guard();
				await source.assertLegacyRetired();
				await names();
				await guard();
			},
			async prepare() {
				await guard();
				return {
					version: 1,
					workspace: owner.workspace,
					source: sourceId,
					target: targetId,
					phase: 'copying'
				};
			},
			async captureLegacy(manifest) {
				await guard();
				bound(manifest);
				return collectWorkspaceSourceInventory({ ...source, sqlite: database.source });
			},
			async copyToEncryptedTarget(manifest) {
				await guard();
				bound(manifest);
				await database.assertTargetEncrypted();
				const captured = await host.captureLegacy(manifest);
				try {
					const bytes = encode(captured),
						before = await proofCell.read();
					try {
						await proofCell.replace(before, bytes);
					} finally {
						bytes.fill(0);
						before?.fill(0);
					}
					await database.copyIntoTarget();
					await database.assertTargetEncrypted();
					await guard();
					await preferences.replace(await preferences.read(), storageMap(captured));
					const credential = JSON.parse(
						decoder.decode(captured.credential[0].value)
					) as HubConnection | null;
					await credentials.replace(await credentials.read(), credential);
					for (const domain of ['files', 'backups'] as const) {
						const previous = await trees[domain].metadata();
						await trees[domain].copy(previous?.revision ?? null, await directory(domain));
					}
					await pending(captured, true);
					await guard();
				} finally {
					wipe(captured);
				}
			},
			async captureEncryptedTarget(manifest) {
				await guard();
				bound(manifest);
				await database.assertTargetEncrypted();
				const captured = await proof();
				try {
					await pending(captured, false);
					const value: WorkspaceMigrationSnapshot = {
						...(await collectSQLiteInventory(database.target)),
						'governance-journal': captured['governance-journal'].map((row) => ({
							key: row.key,
							value: new Uint8Array(row.value)
						})),
						'changeset-journal': captured['changeset-journal'].map((row) => ({
							key: row.key,
							value: new Uint8Array(row.value)
						})),
						...collectWebStorageInventory(asStorage(await preferences.read())),
						credential: collectConsumerCredentialInventory(await credentials.read()),
						files: await targetFiles('files'),
						backups: await targetFiles('backups')
					};
					await guard();
					return value;
				} finally {
					wipe(captured);
				}
			},
			async cleanupLegacy(manifest) {
				await guard();
				bound(manifest);
				const current = await host.readManifest();
				if (
					!current ||
					current.phase !== 'cleanup' ||
					!(['version', 'workspace', 'source', 'target', 'phase'] as const).every(
						(key) => current[key] === manifest[key]
					)
				)
					throw unavailable();
				const expected = await proof();
				try {
					const actual = await host.captureEncryptedTarget(manifest);
					try {
						assertMigrationPreserved(expected, actual);
					} finally {
						wipe(actual);
					}
					await host.assertLegacyRetired();
					for (const domain of ['files', 'backups'] as const) {
						const root = await directory(domain);
						if (root) await trees[domain].verify(root);
					}
					const remaining = await collectLegacyJournalInventory(source.journals);
					try {
						for (const domain of ['governance-journal', 'changeset-journal'] as const) {
							const schema = remaining[domain].find((row) => row.key.endsWith(',"schema"]'));
							if (!schema || JSON.parse(decoder.decode(schema.value)).exists !== false) {
								const a = empty(),
									b = empty();
								a[domain] = expected[domain];
								b[domain] = remaining[domain];
								assertMigrationPreserved(a, b);
							}
						}
					} finally {
						for (const rows of Object.values(remaining)) for (const row of rows) row.value.fill(0);
					}
					// Check remaining source metadata before any irreversible store removal.
					const expectedStorage = storageMap(expected);
					for (const [key, value] of expectedStorage) {
						const current = source.storage.getItem(key);
						if (current !== null && current !== value)
							throw new Error('Legacy preference changed before cleanup.');
					}
					const currentConnection = source.readConnection();
					const credentialCheck = collectConsumerCredentialInventory(currentConnection)[0].value;
					try {
						if (currentConnection !== null && !same(credentialCheck, expected.credential[0].value))
							throw new Error('Legacy credential changed before cleanup.');
					} finally {
						credentialCheck.fill(0);
					}
					await database.closeSource();
					await guard();
					for (const name of legacyNames) {
						try {
							await source.root.removeEntry(name, {
								recursive: Object.values(rootNames).includes(name as never)
							});
						} catch (error) {
							if (!(error instanceof DOMException && error.name === 'NotFoundError')) throw error;
						}
						await guard();
					}
					for (const name of ['iris-governance', 'iris-changesets'])
						await new Promise<void>((resolve, reject) => {
							const request = source.journals.deleteDatabase(name);
							request.onsuccess = () => resolve();
							request.onerror = () => reject(unavailable());
							request.onblocked = () => reject(new Error('Legacy journal cleanup is blocked.'));
						});
					for (const [key, value] of expectedStorage) {
						const current = source.storage.getItem(key);
						if (current !== null && current !== value)
							throw new Error('Legacy preference changed before cleanup.');
						source.storage.removeItem(key);
						await guard();
					}
					const credential = JSON.parse(
						decoder.decode(expected.credential[0].value)
					) as HubConnection | null;
					await source.clearConnection(credential);
					await guard();
				} finally {
					wipe(expected);
				}
			},
			async verifyLegacyAbsent(manifest) {
				await guard();
				bound(manifest);
				await names();
				for await (const [name] of source.root as unknown as AsyncIterable<
					[string, FileSystemHandle]
				>)
					if (legacyNames.has(name)) return false;
				const dbs = await source.journals.databases();
				if (dbs.some((db) => db.name === 'iris-governance' || db.name === 'iris-changesets'))
					return false;
				const expected = await proof();
				try {
					for (const key of storageMap(expected).keys())
						if (source.storage.getItem(key) !== null) return false;
					if (source.readConnection() !== null) return false;
					await guard();
					return true;
				} finally {
					wipe(expected);
				}
			},
			close() {
				closed = true;
				disposeAll();
			}
		};
		await admission.run(async (resource, signal) => {
			if (
				signal !== owner.signal ||
				resource.workspace !== owner.workspace ||
				resource.generation !== owner.generation
			)
				throw unavailable();
		});
		return host;
	} catch {
		try {
			disposeAll();
		} catch {
			throw new Error('Migration host initialization and cleanup failed.');
		}
		throw unavailable();
	}
}
