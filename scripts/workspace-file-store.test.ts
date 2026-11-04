import { expect, test } from 'bun:test';
import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const { createWorkerFileStore } = await import(
	process.env.IRIS_TEST_FILE_STORE || '../apps/web/src/lib/workspace-file-store'
);
async function fixture() {
	let revision = 0,
		fail = false;
	const records = new Map<string, EncryptedWorkspaceRecord>();
	const admission = createWorkspaceAdmission({
		revisions: {
			read: async () => revision,
			advance: async () => ++revision,
			subscribe: () => () => {}
		},
		close: async () => {}
	});
	await admission.unlock(async () => ({
		root: new Uint8Array(32).fill(73),
		workspace: 'synthetic',
		generation: 1
	}));
	const openStore = async (_workspace: string, id: string) => ({
		read: async () => structuredClone(records.get(id) ?? null),
		compareAndSwap: async (
			before: EncryptedWorkspaceRecord | null,
			next: EncryptedWorkspaceRecord
		) => {
			if (fail) throw Error('save failed');
			if (JSON.stringify(before) !== JSON.stringify(records.get(id) ?? null)) return false;
			records.set(id, structuredClone(next));
			return true;
		},
		close() {}
	});
	const store = await createWorkerFileStore({
		admission,
		openStore,
		domain: 'backups',
		id: 'staged/synthetic.sqlite'
	});
	return {
		store,
		admission,
		records,
		reopen: () =>
			createWorkerFileStore({
				admission,
				openStore,
				domain: 'backups',
				id: 'staged/synthetic.sqlite'
			}),
		set fail(value: boolean) {
			fail = value;
		}
	};
}
test('bounded file chunks preserve all bytes and metadata across reopen without plaintext storage', async () => {
	const f = await fixture();
	const payload = new Uint8Array(1024 * 1024 + 19);
	for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
	const source = new File([payload], 'synthetic.sqlite', {
		type: 'application/octet-stream',
		lastModified: 17
	});
	try {
		expect(await f.store.metadata()).toBeNull();
		await f.store.replace(null, source);
		const meta = await f.store.metadata();
		expect(meta).toMatchObject({
			name: source.name,
			size: payload.length,
			type: source.type,
			lastModified: 17
		});
		const parts: Uint8Array[] = [];
		for await (const part of f.store.read()) parts.push(part);
		expect(parts.length).toBe(2);
		expect(new Uint8Array(await new Blob(parts).arrayBuffer())).toEqual(payload);
		expect(JSON.stringify([...f.records])).not.toContain('synthetic.sqlite');
		expect(f.records.size).toBe(3);
		await expect(f.store.replace(null, source)).rejects.toThrow();
		expect((await f.store.metadata())?.revision).toBe(meta?.revision);
	} finally {
		f.store.close();
		await f.admission.close();
	}
});
test('failed replacement preserves prior publication and authenticated tamper rejects reads', async () => {
	const f = await fixture();
	try {
		await f.store.replace(null, new File(['old'], 'old', { lastModified: 1 }));
		const prior = await f.store.metadata();
		f.fail = true;
		await expect(f.store.replace(prior!.revision, new File(['new'], 'new'))).rejects.toThrow();
		f.fail = false;
		expect((await f.store.metadata())?.revision).toBe(prior!.revision);
		const chunks = [...f.records.values()];
		chunks[0].ciphertext[0] ^= 1;
		await expect(
			(async () => {
				for await (const _ of f.store.read()) {
				}
			})()
		).rejects.toThrow();
	} finally {
		f.store.close();
		await f.admission.close();
	}
});
test('closed and revoked file handles cannot disclose bytes or publish; oversized input fails before reading', async () => {
	const f = await fixture();
	try {
		let reads = 0;
		await expect(
			f.store.replace(null, {
				size: 2 ** 40,
				name: 'oversized',
				type: '',
				lastModified: 1,
				slice() {
					reads++;
					throw Error('read');
				}
			} as unknown as File)
		).rejects.toThrow();
		expect(reads).toBe(0);
		await f.store.replace(null, new File(['pending'], 'file'));
		const count = f.records.size;
		await f.admission.lock();
		await expect(f.store.metadata()).rejects.toThrow();
		await expect(
			(async () => {
				for await (const _ of f.store.read()) {
				}
			})()
		).rejects.toThrow();
		expect(f.records.size).toBe(count);
	} finally {
		f.store.close();
		await f.admission.close();
	}
});

test('cold adapter reopen preserves empty files and exact names without creating data on read', async () => {
	const f = await fixture();
	try {
		await f.store.replace(
			null,
			new File([], 'empty.stage', { type: 'text/plain', lastModified: -1 })
		);
		f.store.close();
		const reopened = await f.reopen();
		try {
			expect(await reopened.metadata()).toMatchObject({
				name: 'empty.stage',
				size: 0,
				chunks: 0,
				lastModified: -1
			});
			let count = 0;
			for await (const _ of reopened.read()) count++;
			expect(count).toBe(0);
			expect(f.records.size).toBe(1);
		} finally {
			reopened.close();
		}
	} finally {
		await f.admission.close();
	}
});
test('source changes during fresh copy verification leave old manifest and encrypted staging intact', async () => {
	const f = await fixture();
	try {
		await f.store.replace(null, new File(['old'], 'old'));
		const prior = await f.store.metadata();
		let reads = 0;
		const changing = {
			name: 'stage',
			type: '',
			lastModified: 1,
			size: 3,
			slice() {
				return new Blob([++reads === 1 ? 'new' : 'bad']);
			}
		} as unknown as File;
		await expect(f.store.replace(prior!.revision, changing)).rejects.toThrow();
		expect((await f.store.metadata())?.revision).toBe(prior!.revision);
		expect(f.records.size).toBe(3);
	} finally {
		f.store.close();
		await f.admission.close();
	}
});
test('lock between yielded chunks rejects further reads without deleting acknowledged ciphertext', async () => {
	const f = await fixture();
	try {
		await f.store.replace(null, new File([new Uint8Array(1024 * 1024 + 1)], 'file'));
		const count = f.records.size;
		const reader = f.store.read();
		const first = await reader.next();
		expect(first.value?.length).toBe(1024 * 1024);
		first.value?.fill(0);
		await f.admission.lock();
		await expect(reader.next()).rejects.toThrow();
		expect(f.records.size).toBe(count);
	} finally {
		f.store.close();
		await f.admission.close();
	}
});

test('failure after a staged chunk leaves prior manifest readable and never deletes staged bytes', async () => {
	const f = await fixture();
	try {
		await f.store.replace(null, new File(['old'], 'old'));
		const prior = await f.store.metadata();
		const source = {
			name: 'large',
			type: '',
			lastModified: 1,
			size: 1024 * 1024 + 1,
			slice(begin: number, end: number) {
				if (begin > 0) throw Error('source read failed');
				return new Blob([new Uint8Array(end - begin)]);
			}
		} as unknown as File;
		await expect(f.store.replace(prior!.revision, source)).rejects.toThrow();
		expect((await f.store.metadata())?.revision).toBe(prior!.revision);
		expect(f.records.size).toBe(3);
		const parts = [];
		for await (const part of f.store.read()) parts.push(part);
		expect(await new Blob(parts).text()).toBe('old');
	} finally {
		f.store.close();
		await f.admission.close();
	}
});
