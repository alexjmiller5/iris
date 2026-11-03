import { afterEach, expect, test } from 'bun:test';
import { createRequire } from 'node:module';
const { OPFSCoopSyncVFS } = await import(
	createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve(
		'wa-sqlite/src/examples/OPFSCoopSyncVFS.js'
	)
);
import { withOpfsKeyLease } from '../apps/web/src/lib/opfs-key-lease';

interface TestVfs {
	mapIdToFile: Map<number, unknown>;
	persistentFiles: Map<string, unknown>;
	lastError: Error | null;
	jRead(id: number, bytes: Uint8Array, offset: number): number;
	jLock(id: number, lock: number): number;
	jUnlock(id: number, lock: number): number;
	jClose(id: number): number;
}
const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
afterEach(() => {
	if (originalNavigator) Object.defineProperty(globalThis, 'navigator', originalNavigator);
	else Reflect.deleteProperty(globalThis, 'navigator');
});
function fixture() {
	const module = { retryOps: [] as Promise<unknown>[] };
	const vfs = new OPFSCoopSyncVFS('synthetic-key-lease', module) as unknown as TestVfs;
	let closed = 0,
		acquired = 0;
	const makeHandle = () => ({
		read: (target: Uint8Array) => {
			target.fill(47);
			return target.length;
		},
		close: () => {
			closed++;
		}
	});
	const persistent = {
		accessHandle: makeHandle() as ReturnType<typeof makeHandle> | null,
		handleLockReleaser: (() => {}) as (() => void) | null,
		isFileLocked: false,
		isLockBusy: false,
		isRequestInProgress: false,
		isHandleRequested: false,
		handleRequestChannel: { name: 'synthetic-lease', postMessage: () => {}, onmessage: null },
		fileHandle: {
			createSyncAccessHandle: async () => {
				acquired++;
				return makeHandle();
			}
		}
	};
	const id = 101;
	vfs.mapIdToFile.set(id, { path: '/synthetic.db', flags: 0x100, persistentFile: persistent });
	vfs.persistentFiles.set('/synthetic.db', persistent);
	Object.defineProperty(globalThis, 'navigator', {
		configurable: true,
		value: {
			locks: { request: (_name: string, work: (lock: object) => Promise<void>) => work({}) }
		}
	});
	return {
		vfs,
		module,
		id,
		persistent,
		get closed() {
			return closed;
		},
		get acquired() {
			return acquired;
		}
	};
}
test('actual pinned VFS reproduces the open-header then unlocked C-key salt-read failure', () => {
	const f = fixture();
	expect(f.vfs.jRead(f.id, new Uint8Array(100), 0)).toBe(0);
	expect(f.closed).toBe(1);
	expect(f.vfs.jRead(f.id, new Uint8Array(16), 0)).toBe(266);
	expect(f.vfs.lastError).toBeInstanceOf(TypeError);
	f.vfs.jClose(f.id);
});
test('C-key salt read reacquires a shared OPFS lease after the initial header read released it', async () => {
	const f = fixture();
	f.vfs.jRead(f.id, new Uint8Array(100), 0);
	f.vfs.lastError = null;
	try {
		const salt = new Uint8Array(16);
		const rc = await withOpfsKeyLease({ vfs: f.vfs, module: f.module, fileId: f.id }, () =>
			f.vfs.jRead(f.id, salt, 0)
		);
		expect(rc).toBe(0);
		expect([...salt]).toEqual(Array(16).fill(47));
		expect(f.acquired).toBe(1);
		expect(f.vfs.lastError).toBeNull();
		expect(f.persistent.isFileLocked).toBe(false);
	} finally {
		f.vfs.jClose(f.id);
	}
});
test('a failing C-key operation still unlocks its file lease', async () => {
	const f = fixture();
	f.vfs.jRead(f.id, new Uint8Array(100), 0);
	try {
		await expect(
			withOpfsKeyLease({ vfs: f.vfs, module: f.module, fileId: f.id }, () => {
				throw Error('Key refused');
			})
		).rejects.toThrow('Key refused');
		expect(f.persistent.isFileLocked).toBe(false);
	} finally {
		f.vfs.jClose(f.id);
	}
});
test('busy without a retry operation cannot call the key API or spin', async () => {
	let called = false,
		locks = 0;
	const vfs = {
		jLock: () => {
			locks++;
			return 5;
		},
		jUnlock: () => 0
	};
	await expect(
		withOpfsKeyLease({ vfs, module: { retryOps: [] }, fileId: 101 }, () => {
			called = true;
		})
	).rejects.toThrow();
	expect(called).toBe(false);
	expect(locks).toBe(1);
});
test('failed lease acquisition never calls the key API', async () => {
	let called = false;
	const module = { retryOps: [] as Promise<unknown>[] };
	const vfs = {
		jLock: () => {
			module.retryOps.push(Promise.reject(Error('Handle busy')));
			return 5;
		},
		jUnlock: () => 0
	};
	await expect(
		withOpfsKeyLease({ vfs, module, fileId: 101 }, () => {
			called = true;
		})
	).rejects.toThrow('Handle busy');
	expect(called).toBe(false);
});
test('aborted lease acquisition denies the key API even if the handle arrives later', async () => {
	const controller = new AbortController();
	let release!: () => void,
		called = false;
	const module = { retryOps: [] as Promise<unknown>[] };
	const vfs = {
		jLock: () => {
			module.retryOps.push(new Promise<void>((resolve) => (release = resolve)));
			return 5;
		},
		jUnlock: () => 0
	};
	const result = withOpfsKeyLease({ vfs, module, fileId: 101, signal: controller.signal }, () => {
		called = true;
	});
	await Promise.resolve();
	controller.abort();
	await expect(result).rejects.toThrow();
	release?.();
	expect(called).toBe(false);
});
test('an unlock failure cannot acknowledge successful key binding', async () => {
	const vfs = { jLock: () => 0, jUnlock: () => 10 };
	await expect(
		withOpfsKeyLease({ vfs, module: { retryOps: [] }, fileId: 101 }, () => 0)
	).rejects.toThrow();
});
test('invalid main-file identity is rejected before accessing the VFS', async () => {
	let called = false;
	const vfs = {
		jLock: () => {
			called = true;
			return 0;
		},
		jUnlock: () => 0
	};
	await expect(
		withOpfsKeyLease({ vfs, module: { retryOps: [] }, fileId: 0 }, () => 0)
	).rejects.toThrow();
	expect(called).toBe(false);
});
