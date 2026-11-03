import { expect, test } from 'bun:test';
const { openWorkspaceControlStore } = (await import(
	process.env.IRIS_TEST_CONTROL_STORE || '../apps/web/src/lib/workspace-control-store'
)) as typeof import('../apps/web/src/lib/workspace-control-store');
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
function fixture(options: { exists?: boolean; strict?: boolean; blocked?: boolean } = {}) {
	let rows = new Map<IDBValidKey, unknown>(),
		closed = 0,
		created = 0,
		hold = false,
		abortWrite = false;
	const waiting: Array<() => void> = [];
	const transactions: { mode: string; durability?: string }[] = [];
	const db = {
		objectStoreNames: { length: 1, contains: (name: string) => name === 'control' },
		onversionchange: null as null | (() => void),
		close: () => closed++,
		createObjectStore: () => {
			created++;
		},
		transaction: (_name: string, mode: string, config?: IDBTransactionOptions) => {
			transactions.push({ mode, durability: config?.durability });
			const staged = new Map(rows);
			let aborted = false,
				complete = false;
			const finish = () => {
				if (aborted || complete) return;
				complete = true;
				if (mode === 'readwrite') rows = staged;
				tx.oncomplete?.();
			};
			const tx = {
				durability: options.strict === false ? 'default' : (config?.durability ?? 'default'),
				oncomplete: null as null | (() => void),
				onabort: null as null | (() => void),
				onerror: null,
				error: null,
				abort: () => {
					if (aborted || complete) throw Error('Inactive');
					aborted = true;
					queueMicrotask(() => tx.onabort?.());
				},
				objectStore: () => ({
					keyPath: null,
					autoIncrement: false,
					indexNames: { length: 0 },
					openCursor: (key: IDBValidKey) => {
						const request = {
							result: null as { value: unknown } | null,
							onsuccess: null as null | (() => void)
						};
						queueMicrotask(() => {
							if (aborted) return;
							request.result = staged.has(key) ? { value: structuredClone(staged.get(key)) } : null;
							request.onsuccess?.();
						});
						return request;
					},
					put: (value: unknown, key: IDBValidKey) => {
						staged.set(key, structuredClone(value));
						if (abortWrite) {
							abortWrite = false;
							tx.abort();
						}
						return {};
					}
				})
			};
			setTimeout(() => {
				if (hold) waiting.push(finish);
				else finish();
			}, 0);
			return tx;
		}
	};
	const factory = {
		open: () => {
			const opening = {
				result: db,
				onblocked: null as null | (() => void),
				onerror: null as null | (() => void),
				onsuccess: null as null | (() => void),
				onupgradeneeded: null as null | ((event: { oldVersion: number }) => void),
				error: new Error('Missing existing database'),
				transaction: {
					abort: () => {
						aborted = true;
					}
				}
			};
			let aborted = false;
			queueMicrotask(() => {
				if (options.blocked) opening.onblocked?.();
				if (options.exists === false) opening.onupgradeneeded?.({ oldVersion: 0 });
				if (aborted) opening.onerror?.();
				else opening.onsuccess?.();
			});
			return opening;
		}
	};
	return {
		factory: factory as unknown as IDBFactory,
		db,
		transactions,
		get rows() {
			return rows;
		},
		get closed() {
			return closed;
		},
		get created() {
			return created;
		},
		set hold(value: boolean) {
			hold = value;
		},
		set abortWrite(value: boolean) {
			abortWrite = value;
		},
		release() {
			hold = false;
			for (const finish of waiting.splice(0)) finish();
		}
	};
}
const record = (byte: number): EncryptedWorkspaceRecord => ({
	version: 1,
	iv: new Uint8Array(12).fill(byte),
	ciphertext: new Uint8Array(16).fill(byte)
});
test('strict control CAS resolves only after transaction completion and rejects stale snapshots', async () => {
	const f = fixture(),
		store = await openWorkspaceControlStore('workspace-1', { indexedDB: f.factory });
	f.hold = true;
	let acknowledged = false;
	const writing = store.compareAndSwap(null, record(1)).then((value) => {
		acknowledged = true;
		return value;
	});
	await new Promise((res) => setTimeout(res, 2));
	expect(acknowledged).toBe(false);
	expect(f.rows.size).toBe(0);
	f.release();
	expect(await writing).toBe(true);
	const loaded = await store.read();
	expect(loaded).toEqual(record(1));
	expect(await store.compareAndSwap(null, record(2))).toBe(false);
	expect(await store.compareAndSwap(record(1), record(2))).toBe(true);
	expect(await store.read()).toEqual(record(2));
	expect(
		f.transactions.filter((t) => t.mode === 'readwrite').every((t) => t.durability === 'strict')
	).toBe(true);
	store.close();
});
test('aborted control write cannot acknowledge or alter the previously durable cell', async () => {
	const f = fixture(),
		store = await openWorkspaceControlStore('workspace-1', { indexedDB: f.factory });
	await store.compareAndSwap(null, record(1));
	f.abortWrite = true;
	await expect(store.compareAndSwap(record(1), record(2))).rejects.toThrow();
	expect(await store.read()).toEqual(record(1));
	store.close();
});
test('ignored strict durability and blocked late openings close their handles', async () => {
	for (const options of [{ strict: false }, { blocked: true }]) {
		const f = fixture(options);
		await expect(
			openWorkspaceControlStore('workspace-1', { indexedDB: f.factory })
		).rejects.toThrow();
		expect(f.closed).toBeGreaterThan(0);
	}
});
test('missing legacy control does not create a replacement unless setup explicitly permits creation', async () => {
	const missing = fixture({ exists: false });
	await expect(
		openWorkspaceControlStore('workspace-1', { indexedDB: missing.factory })
	).rejects.toThrow();
	expect(missing.created).toBe(0);
	const setup = fixture({ exists: false });
	const store = await openWorkspaceControlStore('workspace-1', {
		indexedDB: setup.factory,
		create: true
	});
	expect(setup.created).toBe(1);
	expect(await store.read()).toBeNull();
	store.close();
});
test('version change closes cached control connection and no unavailable backend becomes empty', async () => {
	const f = fixture(),
		store = await openWorkspaceControlStore('workspace-1', { indexedDB: f.factory });
	f.db.onversionchange?.();
	await expect(store.read()).rejects.toThrow();
	await expect(
		openWorkspaceControlStore('workspace-1', { indexedDB: undefined })
	).rejects.toThrow();
	expect(f.closed).toBe(1);
});
