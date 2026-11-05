import { expect, test } from 'bun:test';
import { Database, constants } from 'bun:sqlite';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { collectSQLiteInventory } from '../apps/web/src/lib/workspace-sqlite-inventory';
import { assertMigrationPreserved } from '../apps/web/src/lib/workspace-migration';
import { initCore, openSearchIndex } from 'iris-core/client';
const { planSQLiteLogicalCopy } = (await import(
	process.env.IRIS_TEST_SQLITE_COPY || '../apps/web/src/lib/workspace-sqlite-copy'
)) as typeof import('../apps/web/src/lib/workspace-sqlite-copy');
function fixture(path = ':memory:') {
	const db = new Database(
		path,
		constants.SQLITE_OPEN_READWRITE | constants.SQLITE_OPEN_CREATE | constants.SQLITE_OPEN_URI
	);
	const driver = {
		all: async (sql: string, params: unknown[] = []) =>
			db.query(sql).all(...(params as never[])) as Record<string, unknown>[],
		transaction: async <T>(work: () => Promise<T>) => {
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
	};
	return { db, driver };
}
test('plans actual canonical core, hidden identities, generated fields and sequence without source writes', async () => {
	const { db, driver } = fixture();
	try {
		await initCore({
			...driver,
			run: async (sql: string) => {
				db.exec(sql);
			}
		} as never);
		db.exec(
			"PRAGMA user_version=17;PRAGMA application_id=-19;CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT,body TEXT,derived TEXT GENERATED ALWAYS AS(body||'!') STORED);INSERT INTO records(id,body) VALUES(71,'retained');UPDATE sqlite_sequence SET seq=999 WHERE name='records';CREATE TABLE masked(rowid TEXT,value BLOB);INSERT INTO masked(_rowid_,rowid,value) VALUES(-71,'label',x'00FF');CREATE TABLE keyed(k TEXT PRIMARY KEY,v TEXT) WITHOUT ROWID;INSERT INTO _core_pending VALUES('records','71','dirty');INSERT INTO _core_history_hold VALUES('records','71','retained-history');CREATE INDEX records_body ON records(body);CREATE VIEW record_values AS SELECT body FROM records;CREATE TRIGGER records_audit AFTER INSERT ON records BEGIN INSERT INTO keyed VALUES(new.body,'event');END;"
		);
		const before = db.serialize();
		const plan = await planSQLiteLogicalCopy(driver);
		expect(plan.requiresShadowWrites).toBe(false);
		expect(plan.metadata).toEqual({
			user_version: 17,
			application_id: -19,
			encoding: 'UTF-8',
			auto_vacuum: 0
		});
		expect(plan.copies.find((t) => t.name === 'records')).toMatchObject({
			columns: ['id', 'body'],
			rowid: 'rowid',
			clear: false
		});
		expect(plan.copies.find((t) => t.name === 'masked')?.rowid).toBe('_rowid_');
		expect(plan.copies.find((t) => t.name === 'keyed')?.rowid).toBeNull();
		expect(plan.copies.find((t) => t.name === 'sqlite_sequence')?.clear).toBe(true);
		expect(plan.creates.some((sql) => sql.includes('CREATE TABLE sqlite_sequence'))).toBe(false);
		expect(plan.copies.some((t) => t.name === '_core_pending')).toBe(true);
		expect(plan.copies.some((t) => t.name === '_core_history_hold')).toBe(true);
		expect(plan.deferred.some((sql) => sql.includes('CREATE TRIGGER records_audit'))).toBe(true);
		expect(plan.deferred.some((sql) => sql.includes('CREATE INDEX records_body'))).toBe(true);
		expect(plan.deferred.some((sql) => sql.includes('CREATE VIEW record_values'))).toBe(true);
		expect(db.serialize()).toEqual(before);
	} finally {
		db.close();
	}
});
test('default FTS5 copies exact engine-owned shadows once, never visible rows as well', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			"CREATE VIRTUAL TABLE search USING fts5(body);INSERT INTO search(rowid,body) VALUES(71,'retained');CREATE TABLE search_extra(v TEXT);INSERT INTO search_extra VALUES('ordinary');"
		);
		const plan = await planSQLiteLogicalCopy(driver);
		expect(plan.creates.some((sql) => sql.includes('CREATE VIRTUAL TABLE search'))).toBe(true);
		expect(plan.creates.some((sql) => sql.includes("CREATE TABLE 'search_data'"))).toBe(false);
		expect(plan.copies.filter((t) => t.name === 'search')).toHaveLength(0);
		expect(plan.requiresShadowWrites).toBe(true);
		expect(plan.copies.filter((t) => t.name.startsWith('search_') && t.clear)).toHaveLength(5);
		expect(plan.copies.find((t) => t.name === 'search_extra')?.clear).toBe(false);
	} finally {
		db.close();
	}
});
test('internal statistics are explicit native initialization and exact row copy, never replay of reserved DDL', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			'CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT);CREATE INDEX records_value ON records(value);ANALYZE;'
		);
		const plan = await planSQLiteLogicalCopy(driver);
		expect(plan.initializeStatistics).toBe(true);
		expect(plan.creates.some((sql) => sql.includes('CREATE TABLE sqlite_stat1'))).toBe(false);
		expect(plan.copies.find((t) => t.name === 'sqlite_stat1')).toMatchObject({
			clear: true,
			columns: ['tbl', 'idx', 'stat'],
			rowid: 'rowid'
		});
	} finally {
		db.close();
	}
});
test('unknown FTS variants refuse planning and retain the complete original', async () => {
	for (const definition of ["fts5(body,content='')", "fts5(body,tokenize='porter')"]) {
		const { db, driver } = fixture();
		try {
			db.exec('CREATE VIRTUAL TABLE search USING ' + definition);
			const before = db.serialize();
			await expect(planSQLiteLogicalCopy(driver)).rejects.toThrow();
			expect(db.serialize()).toEqual(before);
		} finally {
			db.close();
		}
	}
});

test('native SQL oracle materializes the complete canonical plan with exact rows/schema/metadata and unchanged readonly source', async () => {
	const dir = mkdtempSync(join(tmpdir(), 'iris-copy-plan-'));
	const sourcePath = join(dir, 'source ?#.db'),
		targetPath = join(dir, 'target ?#.db');
	const source = fixture(sourcePath);
	let target: ReturnType<typeof fixture> | undefined;
	try {
		await initCore({
			...source.driver,
			run: async (sql: string) => {
				source.db.exec(sql);
			}
		} as never);
		source.db.exec(
			"PRAGMA user_version=17;PRAGMA application_id=-19;CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT,body TEXT,derived TEXT GENERATED ALWAYS AS(body||'!') STORED);INSERT INTO records(id,body) VALUES(71,'retained');UPDATE sqlite_sequence SET seq=999 WHERE name='records';CREATE TABLE masked(rowid TEXT,value BLOB);INSERT INTO masked(_rowid_,rowid,value) VALUES(-71,'label',x'00FF80');CREATE TABLE keyed(k TEXT PRIMARY KEY,v TEXT) WITHOUT ROWID;INSERT INTO _core_pending VALUES('records','71','dirty');INSERT INTO _core_history_hold VALUES('records','71','retained-history');CREATE INDEX records_body ON records(body);CREATE VIEW record_values AS SELECT body FROM records;CREATE TRIGGER records_audit AFTER INSERT ON records BEGIN INSERT INTO keyed VALUES(new.body,'event');END;ANALYZE;"
		);
		source.db.exec(
			"CREATE TABLE emptied(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO emptied(id) VALUES(900);DELETE FROM emptied;UPDATE sqlite_sequence SET seq=9223372036854775000 WHERE name='emptied';CREATE TABLE compound(a TEXT,b INTEGER,v BLOB,PRIMARY KEY(a,b)) WITHOUT ROWID;INSERT INTO compound VALUES('key',-71,x'00FF');CREATE TABLE strict_values(k INTEGER PRIMARY KEY,v BLOB) STRICT;INSERT INTO strict_values VALUES(900,x'80FF');CREATE TABLE z_sequence(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO z_sequence VALUES(900);UPDATE sqlite_sequence SET seq=1 WHERE name='z_sequence';CREATE TABLE cycle_a(id INTEGER PRIMARY KEY,b INTEGER REFERENCES cycle_b(id) DEFERRABLE INITIALLY DEFERRED);CREATE TABLE cycle_b(id INTEGER PRIMARY KEY,a INTEGER REFERENCES cycle_a(id) DEFERRABLE INITIALLY DEFERRED);INSERT INTO cycle_a VALUES(1,2);INSERT INTO cycle_b VALUES(2,1);"
		);
		const plan = await planSQLiteLogicalCopy(source.driver);
		source.db.close();
		const sourceBytes = readFileSync(sourcePath);
		target = fixture(targetPath);
		for (const [name, value] of Object.entries(plan.metadata))
			target.db.exec(`PRAGMA ${name}=${typeof value === 'string' ? `'${value}'` : value}`);
		target.db.run('ATTACH DATABASE ? AS legacy', [pathToFileURL(sourcePath).href + '?mode=ro']);
		let readonly = false;
		try {
			target.db.exec('UPDATE legacy.records SET body=body');
		} catch (error) {
			expect((error as { code: string }).code).toBe('SQLITE_READONLY');
			readonly = true;
		}
		expect(readonly).toBe(true);
		const q = (name: string) => '"' + name.replaceAll('"', '""') + '"';
		const copy = (entry: (typeof plan.copies)[number]) => {
			const names = [...(entry.rowid ? [entry.rowid] : []), ...entry.columns].map(q).join(',');
			if (entry.clear) target!.db.exec(`DELETE FROM main.${q(entry.name)}`);
			target!.db.exec(
				`INSERT INTO main.${q(entry.name)}(${names}) SELECT ${names} FROM legacy.${q(entry.name)}`
			);
		};
		target.db.exec('PRAGMA foreign_keys=ON;BEGIN;PRAGMA defer_foreign_keys=ON');
		if (plan.sequenceBootstrap) {
			const name = q(plan.sequenceBootstrap);
			target.db.exec(
				`CREATE TABLE ${name}(id INTEGER PRIMARY KEY AUTOINCREMENT);DROP TABLE ${name}`
			);
		}
		for (const sql of plan.creates) target.db.exec(sql);
		for (const entry of plan.copies.filter((entry) => entry.kind !== 'statistics')) copy(entry);
		for (const sql of plan.deferred) target.db.exec(sql);
		if (plan.initializeStatistics) target.db.exec('ANALYZE main');
		for (const entry of plan.copies.filter((entry) => entry.kind === 'statistics')) copy(entry);
		target.db.exec('COMMIT;DETACH DATABASE legacy');
		target.db.close();
		target = fixture(targetPath);
		const captured = await collectSQLiteInventory(target.driver);
		const full = (part: typeof captured) => ({
			...part,
			'governance-journal': [],
			'changeset-journal': [],
			files: [],
			backups: [],
			preferences: [],
			recents: [],
			credential: []
		});
		expect(() => assertMigrationPreserved(full(plan.snapshot), full(captured))).not.toThrow();
		expect(target.db.query("SELECT seq FROM sqlite_sequence WHERE name='records'").get()).toEqual({
			seq: 999
		});
		expect(
			target.db
				.query("SELECT CAST(seq AS TEXT) value FROM sqlite_sequence WHERE name='emptied'")
				.get()
		).toEqual({ value: '9223372036854775000' });
		expect(target.db.query('SELECT updated_at FROM _core_history_hold').all()).toEqual([
			{ updated_at: 'retained-history' }
		]);
		expect(target.db.query('SELECT count(*) AS n FROM keyed').get()).toEqual({ n: 0 });
		expect(readFileSync(sourcePath)).toEqual(sourceBytes);
	} finally {
		source.db.close();
		target?.db.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test('inaccessible identities and unowned shadow claims fail before any source mutation', async () => {
	const { db, driver } = fixture();
	try {
		db.exec('CREATE TABLE masked(rowid TEXT,_rowid_ TEXT,oid TEXT);');
		const before = db.serialize();
		await expect(planSQLiteLogicalCopy(driver)).rejects.toThrow();
		expect(db.serialize()).toEqual(before);
		db.exec('DROP TABLE masked;CREATE TABLE imposter(value TEXT);');
		const snapshot = db.serialize();
		await expect(
			planSQLiteLogicalCopy({
				...driver,
				all: async (sql) => {
					const rows = await driver.all(sql);
					return sql === 'PRAGMA main.table_list'
						? rows.map((row) => (row.name === 'imposter' ? { ...row, type: 'shadow' } : row))
						: rows;
				}
			})
		).rejects.toThrow();
		expect(db.serialize()).toEqual(snapshot);
	} finally {
		db.close();
	}
});

test('defensive target shadow-write rejection is retained as a capability limit, never bypassed', async () => {
	const { db, driver } = fixture();
	try {
		db.exec('CREATE VIRTUAL TABLE search USING fts5(body)');
		const before = db.serialize();
		const plan = await planSQLiteLogicalCopy(driver);
		expect(plan.requiresShadowWrites).toBe(true);
		expect(() => db.exec('DELETE FROM search_config')).toThrow();
		expect(db.serialize()).toEqual(before);
	} finally {
		db.close();
	}
});

test('actual canonical search initialization with its explicit unicode61 tokenizer has a complete shadow plan', async () => {
	const { db, driver } = fixture();
	try {
		const core = {
			...driver,
			run: async (sql: string, params: unknown[] = []) => {
				if (params.length) db.query(sql).run(...(params as never[]));
				else db.exec(sql);
			}
		};
		await initCore(core as never);
		await openSearchIndex(core as never);
		const before = db.serialize();
		const plan = await planSQLiteLogicalCopy(driver);
		expect(plan.creates.some((sql) => sql.includes('_core_search_fts USING fts5'))).toBe(true);
		expect(plan.copies.some((entry) => entry.name === '_core_search_docs')).toBe(true);
		expect(
			plan.copies.filter(
				(entry) => entry.kind === 'shadow' && entry.name.startsWith('_core_search_fts_')
			)
		).toHaveLength(5);
		expect(db.serialize()).toEqual(before);
	} finally {
		db.close();
	}
});

test('source read faults roll back their snapshot and a fresh plan can resume without changing any value', async () => {
	const { db, driver } = fixture();
	try {
		db.exec(
			"CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT);INSERT INTO records VALUES(71,'retained');"
		);
		const before = db.serialize();
		for (const fragment of [
			'PRAGMA main.user_version',
			'SELECT type,name,tbl_name,sql',
			'PRAGMA main.table_xinfo',
			'AS _rid'
		]) {
			let observed = false;
			await expect(
				planSQLiteLogicalCopy({
					...driver,
					all: async (sql) => {
						expect(db.inTransaction).toBe(true);
						if (sql.includes(fragment)) {
							observed = true;
							throw new Error('Synthetic read fault');
						}
						return driver.all(sql);
					}
				})
			).rejects.toThrow('Synthetic read fault');
			expect(observed).toBe(true);
			expect(db.inTransaction).toBe(false);
			expect(db.serialize()).toEqual(before);
			const resumed = await planSQLiteLogicalCopy(driver);
			expect(resumed.copies.some((entry) => entry.name === 'records')).toBe(true);
		}
	} finally {
		db.close();
	}
});

test('quoted FTS identifiers retain exact names instead of confusing punctuation with options', async () => {
	for (const [sql, name] of [
		['CREATE VIRTUAL TABLE "quoted""name" USING fts5("body,part)")', 'quoted"name'],
		['CREATE VIRTUAL TABLE `back``name` USING fts5(body)', 'back`name'],
		['CREATE VIRTUAL TABLE [bracket name] USING fts5(body)', 'bracket name']
	]) {
		const { db, driver } = fixture();
		try {
			db.exec(sql);
			const before = db.serialize();
			const plan = await planSQLiteLogicalCopy(driver);
			expect(plan.creates).toContain(sql);
			expect(
				plan.copies.filter((entry) => entry.kind === 'shadow' && entry.name.startsWith(name + '_'))
			).toHaveLength(5);
			expect(db.serialize()).toEqual(before);
		} finally {
			db.close();
		}
	}
});

test('orphan sequence state has an explicit collision-safe native initialization path', async () => {
	for (const collision of [false, true]) {
		const source = fixture(),
			target = fixture();
		try {
			source.db.exec('CREATE TABLE gone(id INTEGER PRIMARY KEY AUTOINCREMENT);DROP TABLE gone');
			if (collision) source.db.exec('CREATE TABLE "__IRIS_COPY_SEQUENCE_SEED"(value TEXT)');
			const before = source.db.serialize();
			const plan = await planSQLiteLogicalCopy(source.driver);
			expect(typeof plan.sequenceBootstrap).toBe('string');
			expect(plan.sequenceBootstrap?.toLowerCase()).not.toBe(
				collision ? '__iris_copy_sequence_seed' : ''
			);
			const q = (name: string) => '"' + name.replaceAll('"', '""') + '"';
			target.db.exec(
				`CREATE TABLE ${q(plan.sequenceBootstrap!)}(id INTEGER PRIMARY KEY AUTOINCREMENT);DROP TABLE ${q(plan.sequenceBootstrap!)}`
			);
			for (const sql of plan.creates) target.db.exec(sql);
			target.db.exec('DELETE FROM sqlite_sequence');
			expect(await collectSQLiteInventory(target.driver)).toEqual(plan.snapshot);
			expect(source.db.serialize()).toEqual(before);
		} finally {
			source.db.close();
			target.db.close();
		}
	}
});
