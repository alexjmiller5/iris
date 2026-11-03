import { expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
const { collectSQLiteInventory } = (await import(
	process.env.IRIS_TEST_SQLITE_INVENTORY || '../apps/web/src/lib/workspace-sqlite-inventory'
)) as typeof import('../apps/web/src/lib/workspace-sqlite-inventory');
import {
	assertMigrationPreserved,
	type WorkspaceMigrationSnapshot
} from '../apps/web/src/lib/workspace-migration';
function fixture() {
	const db = new Database(':memory:');
	db.exec(
		`CREATE TABLE records(id TEXT PRIMARY KEY,big INTEGER,exact REAL,body TEXT,payload BLOB,empty TEXT);CREATE TABLE _core_pending(tbl TEXT,row_id TEXT,updated_at TEXT,PRIMARY KEY(tbl,row_id));CREATE TABLE _core_history_hold(tbl TEXT,row_id TEXT,updated_at TEXT,PRIMARY KEY(tbl,row_id));CREATE TABLE hidden_values(k TEXT PRIMARY KEY,v TEXT) WITHOUT ROWID;CREATE VIRTUAL TABLE search USING fts5(body);CREATE TABLE "odd""table"("odd""column" TEXT);CREATE INDEX records_body ON records(body);CREATE TRIGGER records_insert AFTER INSERT ON records BEGIN INSERT INTO hidden_values VALUES(new.id,'retained');END;INSERT INTO records VALUES('record-1',9223372036854775807,1.2345678901234567,'body',x'00FF80',NULL);INSERT INTO _core_pending VALUES('records','record-1','synthetic-revision');INSERT INTO _core_history_hold VALUES('records','record-1','synthetic-history');INSERT INTO search(rowid,body) VALUES(17,'searchable synthetic text');INSERT INTO "odd""table" VALUES('quoted-name');`
	);
	let snapshot = false;
	const driver = {
		all: async (sql: string) => {
			expect(snapshot).toBe(true);
			return db.query(sql).all() as Record<string, unknown>[];
		},
		transaction: async <T,>(work: () => Promise<T>) => {
			db.exec('BEGIN');
			snapshot = true;
			try {
				const value = await work();
				db.exec('COMMIT');
				return value;
			} catch (error) {
				db.exec('ROLLBACK');
				throw error;
			} finally {
				snapshot = false;
			}
		}
	};
	return { db, driver };
}
function full(
	part: Awaited<ReturnType<typeof collectSQLiteInventory>>
): WorkspaceMigrationSnapshot {
	return {
		...part,
		'governance-journal': [],
		'changeset-journal': [],
		files: [],
		recents: [],
		preferences: [],
		credential: [],
		backups: []
	};
}
test('actual SQLite full inventory includes internal pending/history, virtual shadows, rowids and lossless typed values', async () => {
	const { db, driver } = fixture();
	try {
		const snapshot = await collectSQLiteInventory(driver);
		const values = snapshot['database-values'].map((r) => new TextDecoder().decode(r.value));
		expect(values.join('\n')).toContain('9223372036854775807');
		expect(values.join('\n')).toContain('00FF80');
		expect(values.join('\n')).toContain(
			'synthetic-revision'
				.split('')
				.map((c) => c.charCodeAt(0).toString(16).padStart(2, '0'))
				.join('')
				.toUpperCase()
		);
		expect(snapshot['database-values'].some((r) => r.key.includes('search_data'))).toBe(true);
		expect(snapshot['database-values'].some((r) => r.key.includes('odd\\\"table'))).toBe(true);
		expect(
			snapshot['database-values'].some(
				(r) => r.key.includes('hidden_values') && r.key.includes('pk')
			)
		).toBe(true);
		expect(snapshot['pending-intents'].some((r) => r.key.includes('_core_pending'))).toBe(true);
		const pendingRow = snapshot['pending-intents'].find(
			(r) => r.key === JSON.stringify(['_core_pending', 'rowid', '1'])
		);
		expect(pendingRow).toBeDefined();
		expect(JSON.parse(new TextDecoder().decode(pendingRow!.value))[2]).toEqual([
			'text',
			Buffer.from('synthetic-revision').toString('hex').toUpperCase()
		]);
		expect(snapshot['pending-intents'].some((r) => r.key.includes('_core_history_hold'))).toBe(
			true
		);
		expect(
			snapshot['database-values'].some((r) => r.key === JSON.stringify(['search', 'rowid', '17']))
		).toBe(true);
		assertMigrationPreserved(full(snapshot), full(await collectSQLiteInventory(driver)));
	} finally {
		db.close();
	}
});
test('equal row counts with changed pending or ordinary actual values fail migration preservation', async () => {
	const { db, driver } = fixture();
	try {
		const before = full(await collectSQLiteInventory(driver));
		db.exec("UPDATE _core_pending SET updated_at='changed-but-same-count'");
		const changed = full(await collectSQLiteInventory(driver));
		expect(() => assertMigrationPreserved(before, changed)).toThrow();
		db.exec('UPDATE records SET big=9223372036854775806');
		const changedAgain = full(await collectSQLiteInventory(driver));
		expect(() => assertMigrationPreserved(changed, changedAgain)).toThrow();
	} finally {
		db.close();
	}
});

test('attached databases and unretired temporary state are refused, never silently excluded', async () => {
	for (const sql of [
		"ATTACH ':memory:' AS extra;CREATE TABLE extra.retained(v TEXT)",
		'CREATE TEMP TABLE unsynced_temp(v TEXT)'
	]) {
		const { db, driver } = fixture();
		try {
			db.exec(sql);
			await expect(collectSQLiteInventory(driver)).rejects.toThrow();
		} finally {
			db.close();
		}
	}
});
test('inaccessible hidden rowid and malformed driver cell types fail closed', async () => {
	const { db, driver } = fixture();
	try {
		db.exec('CREATE TABLE inaccessible(rowid TEXT,_rowid_ TEXT,oid TEXT)');
		await expect(collectSQLiteInventory(driver)).rejects.toThrow();
	} finally {
		db.close();
	}
});

test('column chunks and row pages retain last values, generated columns and sqlite_sequence', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			`CREATE TABLE wide(${Array.from({ length: 19 }, (_, i) => 'c' + i + ' TEXT').join(',')});INSERT INTO wide VALUES(${Array.from({ length: 19 }, (_, i) => "'value-" + i + "'").join(',')});CREATE TABLE paged(id INTEGER PRIMARY KEY AUTOINCREMENT,body TEXT,doubled TEXT GENERATED ALWAYS AS(body||body) STORED);INSERT INTO paged(id,body) VALUES(100,'retained');DELETE FROM paged;INSERT INTO paged(body) VALUES('a'),('b'),('c'),('d'),('e'),('f'),('last-page');CREATE VIEW visible_records AS SELECT id FROM records;`
		);
		const snapshot = await collectSQLiteInventory(driver);
		expect(snapshot['database-values'].filter((r) => r.key.includes('paged'))).toHaveLength(7);
		expect(snapshot['database-values'].some((r) => r.key.includes('sqlite_sequence'))).toBe(true);
		expect(
			snapshot['database-schema'].some(
				(r) => r.key === JSON.stringify(['ddl', 'view', 'visible_records'])
			)
		).toBe(true);
		const wide = snapshot['database-values'].find((r) => r.key.includes('wide'))!;
		const cells = JSON.parse(new TextDecoder().decode(wide.value));
		expect(cells).toHaveLength(19);
		expect(cells[18]).toEqual(['text', Buffer.from('value-18').toString('hex').toUpperCase()]);
	} finally {
		db.close();
	}
});
test('oversized cells refuse bounded inventory without mutating or truncating source', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			'CREATE TABLE large_payload(v BLOB);INSERT INTO large_payload VALUES(zeroblob(1048577))'
		);
		await expect(collectSQLiteInventory(driver)).rejects.toThrow();
		expect(db.query('SELECT length(v) AS bytes FROM large_payload').get()).toEqual({
			bytes: 1048577
		});
	} finally {
		db.close();
	}
});

test('inventory resource bound stops a wide row before accumulating subsequent column chunks', async () => {
	const db = new Database(':memory:');
	try {
		db.exec(
			`CREATE TABLE wide(${Array.from({ length: 20 }, (_, i) => 'c' + i + ' TEXT').join(',')});INSERT INTO wide VALUES(${Array.from({ length: 20 }, () => "'" + 'x'.repeat(1000) + "'").join(',')})`
		);
		let valueQueries = 0;
		const driver = {
			all: async (sql: string) => {
				if (sql.includes('FROM main."wide"')) valueQueries++;
				return db.query(sql).all() as Record<string, unknown>[];
			},
			transaction: async <T,>(work: () => Promise<T>) => {
				db.exec('BEGIN');
				try {
					return await work();
				} finally {
					db.exec('ROLLBACK');
				}
			}
		};
		await expect(collectSQLiteInventory(driver, { budgetBytes: 8192 })).rejects.toThrow();
		expect(valueQueries).toBe(1);
	} finally {
		db.close();
	}
});

test('SQL framing preserves invalid UTF8 text bytes, signed64 minima and real infinities', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			"INSERT INTO records VALUES('record-2',-9223372036854775808,1e999,CAST(x'80FF00' AS TEXT),x'FF',NULL)"
		);
		const snapshot = await collectSQLiteInventory(driver);
		const row = snapshot['database-values'].find(
			(r) => r.key === JSON.stringify(['records', 'rowid', '2'])
		)!;
		const cells = JSON.parse(new TextDecoder().decode(row.value));
		expect(cells[1]).toEqual(['integer', '-9223372036854775808']);
		expect(cells[2]).toEqual(['real', '7ff0000000000000']);
		expect(cells[3]).toEqual(['text', '80FF00']);
	} finally {
		db.close();
	}
});

test('malformed bridge metadata and scalar types cannot certify a complete inventory', async () => {
	for (const mutate of ['metadata', 'cell']) {
		const { db, driver } = fixture();
		const all = driver.all;
		driver.all = async (sql) => {
			const rows = await all(sql);
			if (mutate === 'metadata' && sql === 'PRAGMA main.table_list')
				return rows.map((row) => (row.name === 'records' ? { ...row, wr: 2 } : row));
			if (mutate === 'cell' && sql.includes('FROM main."records"'))
				return rows.map((row) => ({ ...row, t0: 'text', v0: 42 }));
			return rows;
		};
		try {
			await expect(collectSQLiteInventory(driver)).rejects.toThrow();
		} finally {
			db.close();
		}
	}
});
