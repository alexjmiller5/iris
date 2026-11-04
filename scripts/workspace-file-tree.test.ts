import { expect, test } from 'bun:test';
import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const { createWorkerFileTree } = await import(
	process.env.IRIS_TEST_FILE_TREE || '../apps/web/src/lib/workspace-file-tree'
);
function directory(name: string, entries: Map<string, unknown> = new Map()) {
	return {
		name,
		kind: 'directory',
		entries,
		async *[Symbol.asyncIterator]() {
			yield* entries;
		}
	};
}
function file(name: string, value: string) {
	return {
		name,
		kind: 'file',
		getFile: async () =>
			new File([value], name, { type: 'application/octet-stream', lastModified: 17 })
	};
}
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
		root: new Uint8Array(32).fill(79),
		workspace: 'synthetic-tree',
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
	const tree = await createWorkerFileTree({ admission, openStore, domain: 'files' });
	return {
		records,
		tree,
		admission,
		reopen: () => createWorkerFileTree({ admission, openStore, domain: 'files' }),
		set fail(value: boolean) {
			fail = value;
		}
	};
}
function source() {
	return directory(
		'iris-attachments',
		new Map<string, unknown>([
			['empty', directory('empty')],
			['.stage-entry', file('.stage-entry', '{"state":"uploading"}')],
			['orphan', directory('orphan', new Map([['bytes', file('bytes', 'orphan bytes')]]))],
			['entry.json', file('entry.json', '{"name":"retained"}')]
		])
	);
}
test('whole encrypted tree preserves stage/orphan bytes, raw metadata and empty directories across reopen', async () => {
	const f = await fixture(),
		root = source();
	try {
		await f.tree.copy(null, root as unknown as FileSystemDirectoryHandle);
		const tree = await f.tree.metadata();
		expect(tree?.directories).toContainEqual(['empty']);
		expect(tree?.files.map((entry: { path: string[] }) => entry.path)).toContainEqual([
			'orphan',
			'bytes'
		]);
		expect(await f.tree.verify(root as unknown as FileSystemDirectoryHandle)).toBe(true);
		const reopened = await f.reopen();
		try {
			expect(await reopened.verify(root as unknown as FileSystemDirectoryHandle)).toBe(true);
		} finally {
			reopened.close();
		}
		expect(JSON.stringify([...f.records])).not.toContain('retained');
		expect(JSON.stringify([...f.records])).not.toContain('uploading');
		expect(root.entries.size).toBe(4);
	} finally {
		f.tree.close();
		await f.admission.close();
	}
});
test('same-size changed bytes, missing stage and extra directory fail exact tree verification', async () => {
	for (const kind of ['bytes', 'stage', 'directory']) {
		const f = await fixture(),
			root = source();
		try {
			await f.tree.copy(null, root as unknown as FileSystemDirectoryHandle);
			if (kind === 'bytes')
				root.entries.set('.stage-entry', file('.stage-entry', '{"state":"different"}'));
			if (kind === 'stage') root.entries.delete('.stage-entry');
			if (kind === 'directory') root.entries.set('extra', directory('extra'));
			await expect(f.tree.verify(root as unknown as FileSystemDirectoryHandle)).rejects.toThrow();
		} finally {
			f.tree.close();
			await f.admission.close();
		}
	}
});
test('failed staged tree replacement preserves prior publication and leaves source untouched', async () => {
	const f = await fixture(),
		root = source();
	try {
		await f.tree.copy(null, root as unknown as FileSystemDirectoryHandle);
		const previous = await f.tree.metadata();
		f.fail = true;
		await expect(
			f.tree.copy(previous!.revision, root as unknown as FileSystemDirectoryHandle)
		).rejects.toThrow();
		f.fail = false;
		expect((await f.tree.metadata())?.revision).toBe(previous!.revision);
		expect(await f.tree.verify(root as unknown as FileSystemDirectoryHandle)).toBe(true);
		await expect(f.tree.copy(null, root as unknown as FileSystemDirectoryHandle)).rejects.toThrow();
		expect(root.entries.size).toBe(4);
	} finally {
		f.tree.close();
		await f.admission.close();
	}
});
test('absent and empty root remain distinct; unknown handles and revoked epochs fail closed', async () => {
	const f = await fixture();
	try {
		await f.tree.copy(null, null);
		expect(await f.tree.verify(null)).toBe(true);
		await expect(
			f.tree.verify(directory('') as unknown as FileSystemDirectoryHandle)
		).rejects.toThrow();
		const prior = await f.tree.metadata();
		await f.tree.copy(prior!.revision, directory('') as unknown as FileSystemDirectoryHandle);
		expect(await f.tree.verify(directory('') as unknown as FileSystemDirectoryHandle)).toBe(true);
		await expect(
			f.tree.copy(
				(await f.tree.metadata())!.revision,
				directory(
					'',
					new Map([['unknown', { name: 'unknown', kind: 'future' }]])
				) as unknown as FileSystemDirectoryHandle
			)
		).rejects.toThrow();
		const count = f.records.size;
		await f.admission.lock();
		await expect(f.tree.metadata()).rejects.toThrow();
		expect(f.records.size).toBe(count);
	} finally {
		f.tree.close();
		await f.admission.close();
	}
});
test('fresh source-byte change after staging cannot publish a tree manifest', async () => {
	const f = await fixture();
	let captures = 0;
	const changing = {
		kind: 'file',
		name: 'bytes',
		getFile: async () => new File([++captures === 1 ? 'old' : 'new'], 'bytes', { lastModified: 17 })
	};
	const root = directory('', new Map([['bytes', changing]]));
	try {
		await expect(f.tree.copy(null, root as unknown as FileSystemDirectoryHandle)).rejects.toThrow();
		expect(await f.tree.metadata()).toBeNull();
		expect(f.records.size).toBeGreaterThan(0);
		expect(root.entries.size).toBe(1);
	} finally {
		f.tree.close();
		await f.admission.close();
	}
});
test('missing or corrupted encrypted target files never certify an intact plaintext source', async () => {
	for (const kind of ['missing', 'tamper']) {
		const f = await fixture(),
			root = source();
		try {
			await f.tree.copy(null, root as unknown as FileSystemDirectoryHandle);
			const key = [...f.records.keys()][0];
			if (kind === 'missing') f.records.delete(key);
			else f.records.get(key)!.ciphertext[0] ^= 1;
			await expect(f.tree.verify(root as unknown as FileSystemDirectoryHandle)).rejects.toThrow();
			expect(root.entries.size).toBe(4);
		} finally {
			f.tree.close();
			await f.admission.close();
		}
	}
});
test('verification never certifies a different tree revision published during source capture', async () => {
	const f = await fixture(),
		root = source();
	let other: Awaited<ReturnType<typeof f.reopen>> | undefined;
	try {
		await f.tree.copy(null, root as unknown as FileSystemDirectoryHandle);
		const prior = await f.tree.metadata();
		other = await f.reopen();
		const racing = {
			name: root.name,
			kind: 'directory',
			async *[Symbol.asyncIterator]() {
				await other!.copy(prior!.revision, root as unknown as FileSystemDirectoryHandle);
				yield* root.entries;
			}
		};
		await expect(f.tree.verify(racing as unknown as FileSystemDirectoryHandle)).rejects.toThrow();
		expect((await f.tree.metadata())?.revision).not.toBe(prior!.revision);
	} finally {
		other?.close();
		f.tree.close();
		await f.admission.close();
	}
});
