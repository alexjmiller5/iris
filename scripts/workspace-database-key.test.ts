import { expect, test } from 'bun:test';
import { bindWorkspaceDatabaseKey } from '../apps/web/src/lib/workspace-database-key';
function fixture() {
	const heap = new Uint8Array(512);
	let locked = false,
		freed = false,
		calls = 0;
	const vfs = {
		lastError: null as unknown,
		jLock: () => {
			locked = true;
			return 0;
		},
		jUnlock: () => {
			locked = false;
			return 0;
		}
	};
	const module = {
		retryOps: [] as Promise<unknown>[],
		HEAPU8: heap,
		_malloc: () => 128,
		_free: () => {
			freed = true;
		}
	};
	return {
		heap,
		vfs,
		module,
		get freed() {
			return freed;
		},
		get calls() {
			return calls;
		},
		bind: (db: number, schema: string, pointer: number, length: number) => {
			calls++;
			expect(locked).toBe(true);
			expect(db).toBe(42);
			expect(schema).toBe('main');
			expect(length).toBe(36);
			expect(new TextDecoder().decode(heap.subarray(pointer, pointer + 4))).toBe('raw:');
			expect([...heap.subarray(pointer + 4, pointer + 36)]).toEqual(Array(32).fill(17));
			return 0;
		}
	};
}
test('C-key binding uses raw binary32 while leased, then wipes/frees temporary WASM bytes', async () => {
	const f = fixture(),
		key = new Uint8Array(32).fill(17);
	await bindWorkspaceDatabaseKey({ ...f, fileId: 101, connection: 42, key });
	expect(f.calls).toBe(1);
	expect(f.freed).toBe(true);
	expect([...f.heap.subarray(128, 164)]).toEqual(Array(36).fill(0));
	expect([...key]).toEqual(Array(32).fill(17));
});
test('C-key failure still wipes/frees temporary key bytes', async () => {
	const f = fixture();
	await expect(
		bindWorkspaceDatabaseKey({
			...f,
			fileId: 101,
			connection: 42,
			key: new Uint8Array(32),
			bind: () => 1
		})
	).rejects.toThrow();
	expect(f.freed).toBe(true);
	expect([...f.heap.subarray(128, 164)]).toEqual(Array(36).fill(0));
});
test('malformed roots never allocate or call the C key API', async () => {
	const f = fixture();
	let allocated = false;
	f.module._malloc = () => {
		allocated = true;
		return 128;
	};
	for (const key of ['x'.repeat(32), Array(32).fill(1), new Uint8Array(31), new Uint8Array(33)])
		await expect(
			bindWorkspaceDatabaseKey({ ...f, fileId: 101, connection: 42, key: key as Uint8Array })
		).rejects.toThrow();
	expect(allocated).toBe(false);
	expect(f.calls).toBe(0);
});
test('allocation failure denies key setup and does not write outside the heap', async () => {
	const f = fixture();
	f.module._malloc = () => 0;
	await expect(
		bindWorkspaceDatabaseKey({ ...f, fileId: 101, connection: 42, key: new Uint8Array(32) })
	).rejects.toThrow();
	expect(f.calls).toBe(0);
	expect(f.freed).toBe(false);
	expect(f.heap.every((x) => x === 0)).toBe(true);
});
test('a C-key success return cannot hide a new VFS read failure', async () => {
	const f = fixture();
	Object.assign(f.vfs, { lastError: null as unknown });
	await expect(
		bindWorkspaceDatabaseKey({
			...f,
			fileId: 101,
			connection: 42,
			key: new Uint8Array(32),
			bind: () => {
				Object.assign(f.vfs, { lastError: Error('Synthetic read failure') });
				return 0;
			}
		})
	).rejects.toThrow();
	expect(f.freed).toBe(true);
	expect([...f.heap.subarray(128, 164)]).toEqual(Array(36).fill(0));
});
