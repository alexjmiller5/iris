import { expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { assertMigrationPreserved } from '../apps/web/src/lib/workspace-migration';
const { collectWorkspaceSourceInventory } = await import(
	process.env.IRIS_TEST_SOURCE_INVENTORY || '../apps/web/src/lib/workspace-inventory-source'
);
function fixture() {
	const db = new Database(':memory:');
	db.exec(
		"CREATE TABLE records(id TEXT,amount INTEGER);INSERT INTO records VALUES('row-1',9223372036854775807);CREATE TABLE _core_pending(tbl TEXT,row_id TEXT);INSERT INTO _core_pending VALUES('records','row-1')"
	);
	let retired = true,
		calls = 0,
		connection: { endpoint: string; token: string } | null = {
			endpoint: 'https://example.test',
			token: 'synthetic-consumer'
		};
	const names = new Map<string, { kind: 'file'; name: string }>([
		['replica', { kind: 'file', name: 'replica' }]
	]);
	const root = {
		async *[Symbol.asyncIterator]() {
			for (const entry of names) yield entry;
		},
		async getDirectoryHandle() {
			throw new DOMException('Absent', 'NotFoundError');
		}
	} as unknown as FileSystemDirectoryHandle;
	const values = new Map([
		['iris:recents:workspace', '{malformed'],
		['unknown', 'preserve']
	]);
	const options = {
		root,
		owners: [{ name: 'replica', kind: 'file' as const, owner: 'sqlite' }],
		journals: { databases: async () => [] } as unknown as IDBFactory,
		sqlite: {
			all: async (sql: string) => db.query(sql).all() as Record<string, unknown>[],
			transaction: async <T,>(work: () => Promise<T>) => {
				db.exec('BEGIN');
				try {
					const value = await work();
					db.exec('COMMIT');
					return value;
				} catch (error) {
					db.exec('ROLLBACK');
					throw error;
				}
			}
		},
		storage: {
			get length() {
				return values.size;
			},
			key: (index: number) => [...values.keys()][index] ?? null,
			getItem: (key: string) => values.get(key) ?? null
		},
		readConnection: () => connection,
		assertLegacyRetired: async () => {
			calls++;
			if (!retired) throw Error('legacy handles active');
		}
	};
	return {
		db,
		options,
		names,
		values,
		get calls() {
			return calls;
		},
		set retired(value: boolean) {
			retired = value;
		},
		set connection(value: typeof connection) {
			connection = value;
		}
	};
}
test('actual collector composes all ten domains including SQLite unsynced values, both journal schemas and raw metadata', async () => {
	const f = fixture();
	try {
		const value = await collectWorkspaceSourceInventory(f.options);
		expect(Object.keys(value).sort()).toEqual(
			[
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
			].sort()
		);
		for (const rows of Object.values(value)) expect(rows.length).toBeGreaterThan(0);
		expect(f.calls).toBe(2);
		expect(
			JSON.stringify(value['database-values'].map((row) => new TextDecoder().decode(row.value)))
		).toContain('9223372036854775807');
		const next = await collectWorkspaceSourceInventory(f.options);
		assertMigrationPreserved(value, next);
		f.db.exec('DELETE FROM _core_pending');
		expect(() => assertMigrationPreserved(value, next)).not.toThrow();
		const missing = await collectWorkspaceSourceInventory(f.options);
		expect(() => assertMigrationPreserved(value, missing)).toThrow();
	} finally {
		f.db.close();
	}
});
test('legacy retirement and unknown root fail before SQLite reads or missing-store creation', async () => {
	const f = fixture();
	try {
		let reads = 0;
		f.options.sqlite.all = async () => {
			reads++;
			throw Error('must not read');
		};
		f.retired = false;
		await expect(collectWorkspaceSourceInventory(f.options)).rejects.toThrow();
		expect(reads).toBe(0);
		f.retired = true;
		f.names.set('unowned-journal', { kind: 'file', name: 'unowned-journal' });
		await expect(collectWorkspaceSourceInventory(f.options)).rejects.toThrow();
		expect(reads).toBe(0);
	} finally {
		f.db.close();
	}
});
test('late namespaces, raw preference changes and credential changes invalidate collected evidence', async () => {
	for (const kind of ['namespace', 'storage', 'credential', 'retirement']) {
		const f = fixture();
		try {
			const read = f.options.journals.databases.bind(f.options.journals);
			f.options.journals.databases = async () => {
				if (kind === 'namespace') f.names.set('late', { kind: 'file', name: 'late' });
				if (kind === 'storage') f.values.set('unknown', 'changed');
				if (kind === 'credential')
					f.connection = { endpoint: 'https://example.test', token: 'replacement' };
				if (kind === 'retirement') f.retired = false;
				return read();
			};
			await expect(collectWorkspaceSourceInventory(f.options)).rejects.toThrow();
		} finally {
			f.db.close();
		}
	}
});
test('explicit absent connection is preserved and known ownership cannot be changed midcapture', async () => {
	const f = fixture();
	try {
		f.connection = null;
		f.options.journals.databases = async () => {
			f.options.owners[0].name = 'late';
			return [];
		};
		const collecting = collectWorkspaceSourceInventory(f.options);
		await expect(collecting).resolves.toBeDefined();
		const value = await collecting;
		expect(new TextDecoder().decode(value.credential[0].value)).toBe('null');
	} finally {
		f.db.close();
	}
});

test('aborted source capture never returns partial evidence or bypasses retirement', async () => {
	const f = fixture();
	try {
		const controller = new AbortController();
		controller.abort();
		await expect(
			collectWorkspaceSourceInventory({ ...f.options, signal: controller.signal })
		).rejects.toThrow();
		expect(f.calls).toBe(0);
		const second = new AbortController();
		f.options.readConnection = () => {
			second.abort();
			return null;
		};
		await expect(
			collectWorkspaceSourceInventory({ ...f.options, signal: second.signal })
		).rejects.toThrow();
	} finally {
		f.db.close();
	}
});
