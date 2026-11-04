import { expect, test } from 'bun:test';
import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
const { createWorkerEncryptedCell, createWorkerCredentialStore, createWorkerWebStorageStore } =
	(await import(
		process.env.IRIS_TEST_HOST_CELL || '../apps/web/src/lib/workspace-host-cell'
	)) as typeof import('../apps/web/src/lib/workspace-host-cell');
import type { WorkspaceControlStore } from '../apps/web/src/lib/workspace-control-store';
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const encoder = new TextEncoder();
async function fixture() {
	const records = new Map<string, EncryptedWorkspaceRecord>(),
		opened: string[] = [];
	let revision = 0,
		noop = false,
		closed = 0;
	const resource = { root: new Uint8Array(32).fill(57), workspace: 'workspace-1', generation: 1 };
	const admission = createWorkspaceAdmission({
		revisions: {
			read: async () => revision,
			advance: async () => ++revision,
			subscribe: () => () => {}
		},
		close: async () => {}
	});
	await admission.unlock(async () => resource);
	const openStore = async (workspace: string, id: string): Promise<WorkspaceControlStore> => {
		expect(workspace).toBe(resource.workspace);
		opened.push(id);
		return {
			read: async () => structuredClone(records.get(id) ?? null),
			compareAndSwap: async (before, next) => {
				if (JSON.stringify(before) !== JSON.stringify(records.get(id) ?? null)) return false;
				if (!noop) records.set(id, structuredClone(next));
				return true;
			},
			close: () => {
				closed++;
			}
		};
	};
	return {
		admission,
		resource,
		records,
		opened,
		openStore,
		get closed() {
			return closed;
		},
		set noop(value: boolean) {
			noop = value;
		}
	};
}
const context = { store: 'retained-metadata', id: 'private-logical-path' };
test('worker-owned cell persists only opaque key/ciphertext while preserving exact bytes and purpose/generation binding', async () => {
	const f = await fixture(),
		cell = await createWorkerEncryptedCell({ ...f, purpose: 'files', context });
	const bytes = encoder.encode('synthetic private bytes');
	try {
		expect(await cell.read()).toBeNull();
		await cell.replace(null, bytes);
		expect(await cell.read()).toEqual(bytes);
		expect(f.opened[0]).toMatch(/^[a-f0-9]{64}$/);
		expect(JSON.stringify([...f.records])).not.toContain('synthetic private');
		const metadata = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
		expect(f.opened[1]).not.toBe(f.opened[0]);
		expect(await metadata.read()).toBeNull();
		metadata.close();
	} finally {
		cell.close();
		await f.admission.close();
	}
});
test('stale compare cannot overwrite current encrypted value and no-op persistence never acknowledges', async () => {
	const f = await fixture(),
		cell = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
	const first = encoder.encode('first'),
		next = encoder.encode('next');
	try {
		await cell.replace(null, first);
		await expect(cell.replace(null, next)).rejects.toThrow();
		f.noop = true;
		await expect(cell.replace(first, next)).rejects.toThrow();
		expect(await cell.read()).toEqual(first);
		expect(first).toEqual(encoder.encode('first'));
		expect(next).toEqual(encoder.encode('next'));
	} finally {
		cell.close();
		await f.admission.close();
	}
});
test('ciphertext mutation fails closed without deleting the retained payload', async () => {
	const f = await fixture(),
		cell = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
	try {
		await cell.replace(null, encoder.encode('retained'));
		f.records.get(f.opened[0])!.ciphertext[0] ^= 1;
		await expect(cell.read()).rejects.toThrow();
		expect(f.records.size).toBe(1);
	} finally {
		cell.close();
		await f.admission.close();
	}
});
test('old cell cannot be reused after lock/reunlock even when owner accidentally reuses the same resource object', async () => {
	const f = await fixture(),
		cell = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
	await cell.replace(null, encoder.encode('retained'));
	await f.admission.lock();
	await f.admission.unlock(async () => f.resource);
	await expect(cell.read()).rejects.toThrow();
	cell.close();
	await f.admission.close();
});
test('locked admission never opens a physical cell and close denies cached operations', async () => {
	const f = await fixture();
	await f.admission.lock();
	await expect(createWorkerEncryptedCell({ ...f, purpose: 'metadata', context })).rejects.toThrow();
	expect(f.opened).toHaveLength(0);
	await f.admission.unlock(async () => f.resource);
	const cell = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
	cell.close();
	await expect(cell.read()).rejects.toThrow();
	expect(f.closed).toBe(1);
	await f.admission.close();
});
test('consumer credential adapter stays private, encrypted and exact through update, null and cold reopen', async () => {
	const f = await fixture(),
		store = await createWorkerCredentialStore(f);
	const connection = {
		endpoint: 'https://example.test/path',
		token: 'synthetic-consumer-credential'
	};
	try {
		expect(await store.read()).toBeNull();
		await store.replace(null, connection);
		expect(await store.read()).toEqual(connection);
		expect(JSON.stringify([...f.records])).not.toContain(connection.token);
		const reopened = await createWorkerCredentialStore(f);
		expect(await reopened.read()).toEqual(connection);
		await expect(reopened.replace(null, { ...connection, token: 'other' })).rejects.toThrow();
		await reopened.replace(connection, null);
		expect(await reopened.read()).toBeNull();
		await reopened.replace(null, connection);
		expect(await reopened.read()).toEqual(connection);
		reopened.close();
	} finally {
		store.close();
		await f.admission.close();
	}
});

test('constructor snapshots purpose and logical context before asynchronous key derivation', async () => {
	const f = await fixture();
	const original = { ...context };
	const options = { ...f, purpose: 'files' as 'files' | 'metadata', context: { ...original } };
	const opening = createWorkerEncryptedCell(options);
	options.purpose = 'metadata';
	options.context.id = 'changed-after-call';
	const cell = await opening;
	try {
		await cell.replace(null, encoder.encode('retained'));
		const reopened = await createWorkerEncryptedCell({ ...f, purpose: 'files', context: original });
		expect(await reopened.read()).toEqual(encoder.encode('retained'));
		reopened.close();
	} finally {
		cell.close();
		await f.admission.close();
	}
});

test('malformed root and byte inputs fail before opening or persisting any cell', async () => {
	const f = await fixture();
	const key = f.resource.root;
	f.resource.root = 'not-a-byte-buffer' as never;
	await expect(createWorkerEncryptedCell({ ...f, purpose: 'metadata', context })).rejects.toThrow();
	expect(f.opened).toHaveLength(0);
	f.resource.root = key;
	const cell = await createWorkerEncryptedCell({ ...f, purpose: 'metadata', context });
	try {
		await expect(cell.replace(null, 'coerced-string' as never)).rejects.toThrow();
		await expect(cell.replace(null, [1, 2] as never)).rejects.toThrow();
		expect(f.records.size).toBe(0);
	} finally {
		cell.close();
		await f.admission.close();
	}
});
test('invalid CAS acknowledgement rejects even if bytes committed, preserving uncertain durable data', async () => {
	const f = await fixture(),
		cell = await createWorkerEncryptedCell({
			...f,
			purpose: 'metadata',
			context,
			openStore: async (w, id) => {
				const store = await f.openStore(w, id);
				return {
					...store,
					compareAndSwap: async (before, next) => {
						await store.compareAndSwap(before, next);
						return NaN as never;
					}
				};
			}
		});
	try {
		await expect(
			cell.replace(null, encoder.encode('committed but unacknowledged'))
		).rejects.toThrow();
		expect(await cell.read()).toEqual(encoder.encode('committed but unacknowledged'));
	} finally {
		cell.close();
		await f.admission.close();
	}
});
test('revocation while opening closes the late acquired cell without acknowledgement', async () => {
	const f = await fixture();
	await expect(
		createWorkerEncryptedCell({
			...f,
			purpose: 'metadata',
			context,
			openStore: async (w, id) => {
				const store = await f.openStore(w, id);
				await f.admission.lock();
				return store;
			}
		})
	).rejects.toThrow();
	expect(f.closed).toBe(1);
	await f.admission.close();
});

test('encrypted web-storage adapter retains every raw recent/preference string and compares exact snapshots', async () => {
	const f = await fixture(),
		store = await createWorkerWebStorageStore(f);
	const values = new Map([
		['iris:recents:workspace', '{unreadable-but-preserved'],
		['future-key', String.fromCharCode(0xd800) + 'raw']
	]);
	try {
		expect(await store.read()).toEqual(new Map());
		await store.replace(new Map(), values);
		expect(await store.read()).toEqual(values);
		expect(JSON.stringify([...f.records])).not.toContain('unreadable-but-preserved');
		await expect(store.replace(new Map(), new Map([['other', 'changed']]))).rejects.toThrow();
		expect(await store.read()).toEqual(values);
	} finally {
		store.close();
		await f.admission.close();
	}
});
