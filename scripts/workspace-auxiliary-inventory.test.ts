import { expect, test } from 'bun:test';
const {
	collectLegacyFileInventory,
	collectWebStorageInventory,
	collectConsumerCredentialInventory
} = (await import(
	process.env.IRIS_TEST_AUXILIARY_INVENTORY || '../apps/web/src/lib/workspace-auxiliary-inventory'
)) as typeof import('../apps/web/src/lib/workspace-auxiliary-inventory');
import {
	assertMigrationPreserved,
	type WorkspaceMigrationSnapshot
} from '../apps/web/src/lib/workspace-migration';
function file(name: string, content: string) {
	let value = new File([content], name, { type: 'application/octet-stream', lastModified: 17 });
	return {
		kind: 'file' as const,
		name,
		getFile: async () => value,
		set value(next: File) {
			value = next;
		}
	};
}
function directory(name: string, entries: Map<string, unknown> = new Map()) {
	return {
		kind: 'directory' as const,
		name,
		entries,
		async *[Symbol.asyncIterator]() {
			for (const [key, value] of entries) yield [key, value];
		},
		getDirectoryHandle: async (key: string, options?: { create?: boolean }) => {
			expect(options?.create).not.toBe(true);
			const found = entries.get(key) as { kind?: string } | undefined;
			if (!found) throw new DOMException('Missing', 'NotFoundError');
			if (found.kind !== 'directory') throw new DOMException('Not directory', 'TypeMismatchError');
			return found;
		}
	};
}
function storage(values: Map<string, string>) {
	return {
		get length() {
			return values.size;
		},
		key: (index: number) => [...values.keys()][index] ?? null,
		getItem: (key: string) => values.get(key) ?? null
	};
}
function full(part: Partial<WorkspaceMigrationSnapshot>): WorkspaceMigrationSnapshot {
	return {
		'database-schema': [],
		'database-values': [],
		'pending-intents': [],
		'governance-journal': [],
		'changeset-journal': [],
		files: [],
		backups: [],
		recents: [],
		preferences: [],
		credential: [],
		...part
	};
}
test('raw attachment and backup inventory includes metadata, stage files, orphan bytes and all backup lanes without refresh', async () => {
	const bytes = file('bytes', 'synthetic attachment'),
		stage = file('.stage-entry', '{"state":"uploading"}'),
		meta = file('entry.json', '{"state":"uploading","name":"retained name"}');
	const attachments = directory(
		'iris-attachments',
		new Map([
			[
				'scope',
				directory(
					'scope',
					new Map([
						['entry', directory('entry', new Map([['bytes', bytes]]))],
						['.stage-entry', stage],
						['entry.json', meta],
						['orphan', directory('orphan', new Map([['bytes', file('bytes', 'orphan data')]]))]
					])
				)
			]
		])
	);
	const backups = directory(
		'backups',
		new Map(
			['staged', 'recovery', 'exports'].map((kind) => [
				kind,
				directory(kind, new Map([[kind + '.sql', file(kind + '.sql', 'synthetic ' + kind)]]))
			])
		)
	);
	const root = directory(
		'',
		new Map([
			['iris-attachments', attachments],
			['backups', backups]
		])
	);
	const snapshot = await collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle);
	expect(snapshot.files.some((row) => row.key.includes('.stage-entry'))).toBe(true);
	expect(snapshot.files.some((row) => row.key.includes('orphan'))).toBe(true);
	for (const kind of ['staged', 'recovery', 'exports'])
		expect(snapshot.backups.some((row) => row.key.includes(kind + '.sql'))).toBe(true);
	const row = snapshot.files.find(
		(row) => row.key === JSON.stringify(['file', 'scope', 'entry', 'bytes'])
	)!;
	expect(JSON.parse(new TextDecoder().decode(row.value))).toEqual({
		bytes: 20,
		modified: 17,
		mime: 'application/octet-stream',
		sha256: new Bun.CryptoHasher('sha256').update('synthetic attachment').digest('hex')
	});
	expect(await (await stage.getFile()).text()).toContain('uploading');
	expect(attachments.entries.size).toBe(1);
});
test('same file count, size and timestamp with different bytes fails preservation by freshly computed hashes', async () => {
	const source = file('bytes', 'first'),
		root = directory(
			'',
			new Map([['iris-attachments', directory('iris-attachments', new Map([['bytes', source]]))]])
		);
	const before = full(
		await collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle)
	);
	source.value = new File(['other'], 'bytes', {
		type: 'application/octet-stream',
		lastModified: 17
	});
	const after = full(
		await collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle)
	);
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});
test('missing directories are explicit and never created; unreadable storage is not treated as empty', async () => {
	const absent = await collectLegacyFileInventory(
		directory('') as unknown as FileSystemDirectoryHandle
	);
	expect(new TextDecoder().decode(absent.files[0].value)).toContain('false');
	expect(new TextDecoder().decode(absent.backups[0].value)).toContain('false');
	const root = {
		getDirectoryHandle: async () => {
			throw new DOMException('Denied', 'SecurityError');
		}
	};
	await expect(
		collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle)
	).rejects.toThrow();
});
test('all local storage strings including malformed recents and unknown preferences are retained exactly', () => {
	const values = new Map([
		['iris:recents:workspace', '{unreadable-recent'],
		['iris:recents:demo', '{"label":"synthetic"}'],
		['iris:replica', '{"all":true}'],
		['future-private-state', String.fromCharCode(0xd800) + 'raw']
	]);
	const captured = collectWebStorageInventory(storage(values));
	expect(captured.recents).toHaveLength(2);
	expect(captured.preferences).toHaveLength(2);
	for (const [key, value] of values) {
		const row = [...captured.recents, ...captured.preferences].find(
			(row) => row.key === JSON.stringify(['localStorage', key])
		)!;
		expect(JSON.parse(new TextDecoder().decode(row.value))).toBe(value);
	}
});
test('local storage changing during capture never certifies a partial snapshot', () => {
	let reads = 0;
	const unstable = {
		length: 1,
		key: () => 'iris:recents:workspace',
		getItem: () => (++reads === 1 ? 'before' : 'after')
	};
	expect(() => collectWebStorageInventory(unstable)).toThrow();
});
test('credential inventory preserves the exact consumer endpoint/token without provider calls or normalization', () => {
	const connection = {
		endpoint: 'https://example.test/path',
		token: 'synthetic-consumer-credential'
	};
	const records = collectConsumerCredentialInventory(connection);
	expect(JSON.parse(new TextDecoder().decode(records[0].value))).toEqual(connection);
	expect(
		JSON.parse(new TextDecoder().decode(collectConsumerCredentialInventory(null)[0].value))
	).toBeNull();
	expect(() =>
		collectConsumerCredentialInventory({ ...connection, providerKey: 'forbidden' } as never)
	).toThrow();
});

test('file size bound is checked before costly allocation and invalid byte lengths never certify hashes', async () => {
	let reads = 0;
	const oversized = new File(['x'], 'large', { lastModified: 17 });
	Object.defineProperty(oversized, 'size', { value: 128 * 1024 * 1024 + 1 });
	oversized.arrayBuffer = async () => {
		reads++;
		return new ArrayBuffer(1);
	};
	const root = directory(
		'',
		new Map([
			[
				'iris-attachments',
				directory(
					'iris-attachments',
					new Map([['large', { kind: 'file', name: 'large', getFile: async () => oversized }]])
				)
			]
		])
	);
	await expect(
		collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle)
	).rejects.toThrow();
	expect(reads).toBe(0);
});
test('unknown file kinds or mismatched names fail instead of silently dropping retained state', async () => {
	for (const node of [
		{ kind: 'unknown', name: 'item' },
		{ kind: 'file', name: 'item', getFile: async () => new File(['x'], 'different-name') }
	]) {
		const root = directory(
			'',
			new Map([['iris-attachments', directory('iris-attachments', new Map([['item', node]]))]])
		);
		await expect(
			collectLegacyFileInventory(root as unknown as FileSystemDirectoryHandle)
		).rejects.toThrow();
	}
});
