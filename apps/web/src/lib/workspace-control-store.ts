import { readEncryptedWorkspaceRecord, type EncryptedWorkspaceRecord } from './workspace-records';
export interface WorkspaceControlStore {
	read(): Promise<EncryptedWorkspaceRecord | null>;
	compareAndSwap(
		before: EncryptedWorkspaceRecord | null,
		next: EncryptedWorkspaceRecord
	): Promise<boolean>;
	close(): void;
}
function copy(value: unknown) {
	const record = readEncryptedWorkspaceRecord(value);
	return {
		version: 1 as const,
		iv: new Uint8Array(record.iv),
		ciphertext: new Uint8Array(record.ciphertext)
	};
}
function equal(a: EncryptedWorkspaceRecord | null, b: EncryptedWorkspaceRecord | null) {
	if (a === null || b === null) return a === b;
	return (
		a.iv.every((v, i) => v === b.iv[i]) &&
		a.ciphertext.length === b.ciphertext.length &&
		a.ciphertext.every((v, i) => v === b.ciphertext[i])
	);
}
/** Dedicated strict-IDB control cell; no other app store is opened or rewritten.
 * Existing-only is the default. New setup must explicitly request create. */
export async function openWorkspaceControlStore(
	workspace: string,
	options: { indexedDB?: IDBFactory; create?: boolean } = {}
): Promise<WorkspaceControlStore> {
	if (
		typeof workspace !== 'string' ||
		!workspace.length ||
		workspace.length > 128 ||
		!/^[a-zA-Z0-9_-]+$/.test(workspace)
	)
		throw new Error('Invalid workspace control namespace.');
	const factory = Object.hasOwn(options, 'indexedDB') ? options.indexedDB : globalThis.indexedDB;
	if (!factory) throw new Error('IndexedDB workspace control is unavailable.');
	const db = await new Promise<IDBDatabase>((resolve, reject) => {
		const opening = factory.open(`iris-control-${workspace}`, 1);
		let failed = false;
		opening.onblocked = () => {
			failed = true;
			reject(new Error('Workspace control opening is blocked.'));
		};
		opening.onerror = () => reject(opening.error ?? new Error('Could not open workspace control.'));
		opening.onupgradeneeded = (event) => {
			if (options.create !== true || event.oldVersion !== 0) {
				opening.transaction?.abort();
				return;
			}
			opening.result.createObjectStore('control');
		};
		opening.onsuccess = () => {
			const opened = opening.result;
			if (
				failed ||
				opened.objectStoreNames.length !== 1 ||
				!opened.objectStoreNames.contains('control')
			) {
				opened.close();
				reject(new Error('Unsupported workspace control database.'));
				return;
			}
			resolve(opened);
		};
	});
	let closed = false;
	db.onversionchange = () => {
		closed = true;
		db.close();
	};
	function transaction<R>(
		mode: IDBTransactionMode,
		work: (store: IDBObjectStore, done: (value: R) => void, fail: (error: unknown) => void) => void
	): Promise<R> {
		return new Promise((resolve, reject) => {
			if (closed) {
				reject(new Error('Workspace control store is closed.'));
				return;
			}
			let tx: IDBTransaction;
			try {
				tx = db.transaction(
					'control',
					mode,
					mode === 'readwrite' ? { durability: 'strict' } : undefined
				);
			} catch (error) {
				reject(error);
				return;
			}
			let result: R, failure: unknown;
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
				reject(failure ?? tx.error ?? new Error('Workspace control transaction aborted.'));
			tx.onerror = () => {
				failure ??= tx.error;
			};
			if (mode === 'readwrite' && tx.durability !== 'strict') {
				fail(new Error('Strict workspace control durability is unsupported.'));
				return;
			}
			try {
				const store = tx.objectStore('control');
				if (store.keyPath !== null || store.autoIncrement || store.indexNames.length)
					throw new Error('Unsupported workspace control store.');
				work(
					store,
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
		await transaction<void>('readwrite', (_store, done) => done());
	} catch (error) {
		closed = true;
		db.close();
		throw error;
	}
	return {
		read: () =>
			transaction<EncryptedWorkspaceRecord | null>('readonly', (store, done, fail) => {
				const request = store.openCursor('state');
				request.onsuccess = () => {
					try {
						done(request.result === null ? null : copy(request.result.value));
					} catch (error) {
						fail(error);
					}
				};
			}),
		compareAndSwap(before, next) {
			const expected = before === null ? null : copy(before),
				replacement = copy(next);
			return transaction<boolean>('readwrite', (store, done, fail) => {
				const request = store.openCursor('state');
				request.onsuccess = () => {
					try {
						const current = request.result === null ? null : copy(request.result.value);
						if (!equal(current, expected)) {
							done(false);
							return;
						}
						store.put(replacement, 'state');
						done(true);
					} catch (error) {
						fail(error);
					}
				};
			});
		},
		close() {
			closed = true;
			db.close();
		}
	};
}
