import type { ApprovalJournal, ApprovalScope, PendingApproval } from './api';

const storeName = 'pending';
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0;
const object = (value: unknown): value is Record<string, unknown> =>
	value !== null && typeof value === 'object' && !Array.isArray(value);
const keys = (value: unknown, expected: string[]): value is Record<string, unknown> =>
	object(value) &&
	Object.keys(value).length === expected.length &&
	expected.every((key) => Object.hasOwn(value, key));
const ids = (value: unknown): value is string[] =>
	Array.isArray(value) && value.every(text) && new Set(value).size === value.length;
function cell(value: unknown): boolean {
	if (!object(value)) return false;
	if (value.type === 'null') return keys(value, ['type']);
	if (!keys(value, ['type', 'value'])) return false;
	if (value.type === 'text') return typeof value.value === 'string';
	if (value.type === 'integer')
		return typeof value.value === 'string' && /^-?(0|[1-9]\d*)$/.test(value.value);
	return value.type === 'real' && typeof value.value === 'number' && Number.isFinite(value.value);
}
function changes(value: unknown, before: boolean): boolean {
	return (
		Array.isArray(value) &&
		value.length > 0 &&
		value.every(
			(change) =>
				keys(change, before ? ['column', 'before', 'after'] : ['column', 'after']) &&
				text(change.column) &&
				cell(change.after) &&
				(!before || cell(change.before))
		) &&
		new Set(value.map((change) => change.column)).size === value.length
	);
}
function validScope(value: unknown): value is ApprovalScope {
	return (
		keys(value, ['deploymentId', 'sessionId', 'principalId']) && Object.values(value).every(text)
	);
}
function scopeKey(scope: ApprovalScope): string {
	if (!validScope(scope)) throw new Error('Invalid approval journal scope.');
	return JSON.stringify([scope.deploymentId, scope.sessionId, scope.principalId]);
}

/** Structural persistence checks only. Inverse, permissions and validation stay in core. */
export function decodePendingApproval(raw: unknown, scope: ApprovalScope): PendingApproval {
	if (typeof raw !== 'string') throw new Error('Unreadable approval journal.');
	let value: unknown;
	try {
		value = JSON.parse(raw);
	} catch {
		throw new Error('Unreadable approval journal.');
	}
	if (
		!keys(value, [
			'version',
			'scope',
			'target',
			'intent',
			'revision',
			'changes',
			'selectedEventIds',
			'request'
		]) ||
		value.version !== 1 ||
		!validScope(value.scope) ||
		scopeKey(value.scope) !== scopeKey(scope) ||
		!keys(value.target, ['table', 'rowId']) ||
		!Object.values(value.target).every(text) ||
		!keys(value.revision, ['updated_at', 'hub_at']) ||
		!text(value.revision.updated_at) ||
		!(value.revision.hub_at === null || text(value.revision.hub_at)) ||
		!keys(value.request, ['proposalId', 'expectedVersion', 'previewToken', 'idempotencyKey']) ||
		!Object.values(value.request).every(text) ||
		!ids(value.selectedEventIds) ||
		!changes(value.changes, true) ||
		!object(value.intent)
	)
		throw new Error('Invalid or unsupported approval journal.');
	const intent = value.intent;
	if (
		!(
			intent.kind === 'selected_inverse' &&
			keys(intent, ['kind', 'eventIds']) &&
			ids(intent.eventIds) &&
			intent.eventIds.length > 0
		) &&
		!(
			intent.kind === 'patch' &&
			keys(intent, ['kind', 'changes']) &&
			changes(intent.changes, false)
		)
	)
		throw new Error('Invalid approval intent in journal.');
	return value as unknown as PendingApproval;
}

export function encodePendingApproval(entry: PendingApproval, scope: ApprovalScope): string {
	const encoded = JSON.stringify(entry);
	decodePendingApproval(encoded, scope);
	return encoded;
}

/** No dispatch may follow retain until its strict transaction completes.
 * IndexedDB serializes overlapping readwrite transactions across connections.
 * https://w3c.github.io/IndexedDB/#transaction-durability-hint
 */
export async function openApprovalJournal(
	scope: ApprovalScope,
	options: { indexedDB?: IDBFactory; databaseName?: string } = {}
): Promise<ApprovalJournal & { close(): void }> {
	const boundScope = { ...scope };
	return openScopedJournal<PendingApproval>(
		scopeKey(boundScope),
		{
			encode: (entry) => encodePendingApproval(entry, boundScope),
			decode: (raw) => decodePendingApproval(raw, boundScope)
		},
		options
	);
}

export interface DurableJournal<T> {
	load(): Promise<T | null>;
	retain(entry: T): Promise<void>;
	resolve(entry: T): Promise<void>;
	close(): void;
}

/** Shared strict IndexedDB persistence; each protocol owns its exact codec/key. */
export async function openScopedJournal<T>(
	key: string,
	codec: { encode(entry: T): string; decode(raw: unknown): T },
	options: { indexedDB?: IDBFactory; databaseName?: string } = {}
): Promise<DurableJournal<T>> {
	if (!key) throw new Error('Missing journal scope.');
	const factory = Object.hasOwn(options, 'indexedDB') ? options.indexedDB : globalThis.indexedDB;
	if (!factory) throw new Error('IndexedDB approval recovery is unavailable.');
	const db = await new Promise<IDBDatabase>((resolve, reject) => {
		const opening = factory.open(options.databaseName ?? 'life-ui-governance', 1);
		let failed = false;
		opening.onblocked = () => {
			failed = true;
			reject(new Error('Approval journal opening is blocked.'));
		};
		opening.onerror = () => reject(opening.error ?? new Error('Could not open approval journal.'));
		opening.onupgradeneeded = (event) => {
			if (event.oldVersion !== 0) {
				opening.transaction?.abort();
				return;
			}
			opening.result.createObjectStore(storeName);
		};
		opening.onsuccess = () => {
			const opened = opening.result;
			if (
				failed ||
				opened.objectStoreNames.length !== 1 ||
				!opened.objectStoreNames.contains(storeName)
			) {
				opened.close();
				reject(new Error('Unsupported approval journal database.'));
				return;
			}
			resolve(opened);
		};
	});
	db.onversionchange = () => db.close();
	function transaction<T>(
		mode: IDBTransactionMode,
		work: (store: IDBObjectStore, done: (value: T) => void, fail: (error: unknown) => void) => void
	): Promise<T> {
		return new Promise((resolve, reject) => {
			let tx: IDBTransaction;
			try {
				tx = db.transaction(
					storeName,
					mode,
					mode === 'readwrite' ? { durability: 'strict' } : undefined
				);
			} catch (error) {
				reject(error);
				return;
			}
			let result: T;
			let failure: unknown;
			const fail = (error: unknown) => {
				failure = error;
				try {
					tx.abort();
				} catch {
					reject(error);
				}
			};
			tx.oncomplete = () => resolve(result);
			tx.onabort = () =>
				reject(failure ?? tx.error ?? new Error('Approval journal transaction aborted.'));
			tx.onerror = () => {
				failure ??= tx.error;
			};
			if (mode === 'readwrite' && tx.durability !== 'strict') {
				fail(new Error('Strict journal durability is unsupported.'));
				return;
			}
			try {
				work(
					tx.objectStore(storeName),
					(value) => {
						result = value;
					},
					fail
				);
			} catch (error) {
				fail(error);
			}
		});
	}
	try {
		// Fail before offering a journal if this browser ignores strict durability.
		await transaction<void>('readwrite', (store, done) => {
			if (store.keyPath !== null || store.autoIncrement || store.indexNames.length !== 0)
				throw new Error('Unsupported approval journal store.');
			done();
		});
	} catch (error) {
		db.close();
		throw error;
	}
	return {
		async load() {
			return transaction<T | null>('readonly', (store, done, fail) => {
				const request = store.openCursor(key);
				request.onsuccess = () => {
					try {
						done(request.result === null ? null : codec.decode(request.result.value));
					} catch (error) {
						fail(error);
					}
				};
			});
		},
		async retain(entry) {
			const encoded = codec.encode(entry);
			await transaction<void>('readwrite', (store, done, fail) => {
				const request = store.openCursor(key);
				request.onsuccess = () => {
					try {
						if (request.result !== null) {
							codec.decode(request.result.value);
							if (request.result.value !== encoded)
								throw new Error('Resolve the existing approval before replacing it.');
						} else store.add(encoded, key);
						done();
					} catch (error) {
						fail(error);
					}
				};
			});
		},
		async resolve(entry) {
			const encoded = codec.encode(entry);
			await transaction<void>('readwrite', (store, done, fail) => {
				const request = store.openCursor(key);
				request.onsuccess = () => {
					try {
						if (request.result !== null) {
							codec.decode(request.result.value);
							if (request.result.value !== encoded)
								throw new Error('Retained approval changed; it was not removed.');
							store.delete(key);
						}
						done();
					} catch (error) {
						fail(error);
					}
				};
			});
		},
		close() {
			db.close();
		}
	};
}
