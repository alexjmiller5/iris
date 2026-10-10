import { describe, expect, it } from 'vitest';
import { DatabaseSync } from 'node:sqlite';
import { createCoreHandlers, type Property, type Row } from 'iris-core/client';
import { referenceLabels } from './reference-labels';

const refs: Property[] = [
	{ tbl: 'wide', col: 'a', type: 'ref', ref_table: 'targets' },
	{ tbl: 'wide', col: 'b', type: 'ref', ref_table: 'targets' },
	{ tbl: 'wide', col: 'c', type: 'ref', ref_table: 'targets' },
	{ tbl: 'wide', col: 'd', type: 'multi_ref', ref_table: 'targets' },
	{ tbl: 'wide', col: 'e', type: 'multi_ref', ref_table: 'targets' }
];

/** The browser Worker's core over node:sqlite: 10,000 wide rows with five reference columns. */
function wideWorkspace(rows = 10_000) {
	const db = new DatabaseSync(':memory:');
	const system =
		'id TEXT PRIMARY KEY NOT NULL, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT';
	db.exec(`CREATE TABLE catalog_tables (${system}, kind TEXT, display TEXT)`);
	db.exec(
		`CREATE TABLE catalog_properties (${system}, tbl TEXT, col TEXT, label TEXT, sort INTEGER, type TEXT, required INTEGER, options TEXT, ref_table TEXT, inputs TEXT, description TEXT)`
	);
	db.exec(
		`CREATE TABLE catalog_rules (${system}, tbl TEXT, col TEXT, kind TEXT, text TEXT, sql TEXT, enforce INTEGER)`
	);
	db.exec(`CREATE TABLE targets (${system}, title TEXT)`);
	db.exec(
		`CREATE TABLE wide (${system}, title TEXT, body TEXT, a TEXT, b TEXT, c TEXT, d TEXT, e TEXT)`
	);
	db.exec(
		`INSERT INTO catalog_tables(id,kind,display) VALUES ('targets','table','title'),('wide','table','title')`
	);
	db.exec(
		`INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('targets.title','targets','title','text'),('wide.title','wide','title','text'),('wide.body','wide','body','text')`
	);
	for (const p of refs)
		db.prepare('INSERT INTO catalog_properties(id,tbl,col,type,ref_table) VALUES (?,?,?,?,?)').run(
			`wide.${p.col}`,
			'wide',
			p.col,
			p.type!,
			'targets'
		);
	db.exec(
		`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300) INSERT INTO targets(id,title) SELECT 'target-'||i,'Target '||i FROM n`
	);
	// Unrelated catalog bulk, as on a large estate.
	db.exec(
		`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1000) INSERT INTO catalog_properties(id,tbl,col,type,description) SELECT 'bulk.'||i,'bulk_'||(i%50),'field_'||i,'text',printf('%.400c','x') FROM n`
	);
	db.prepare(
		`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?) INSERT INTO wide(id,title,body,a,b,c,d,e)
		 SELECT printf('wide-%05d',i),'Row '||i,printf('%.2048c','w'),'target-'||(i%300+1),'target-'||((i+1)%300+1),'target-'||((i+2)%300+1),
		 json_array('target-'||((i+3)%300+1),'target-'||((i+4)%300+1)),json_array('target-'||((i+5)%300+1)) FROM n`
	).run(rows);
	const requests: string[] = [];
	const driver = {
		async all(sql: string, params: (string | number | null)[] = []) {
			return db.prepare(sql).all(...params) as Row[];
		},
		async run(sql: string, params: (string | number | null)[] = []) {
			return Number(db.prepare(sql).run(...params).changes);
		},
		async transaction<T>(body: () => Promise<T>) {
			db.exec('BEGIN IMMEDIATE');
			try {
				const value = await body();
				db.exec('COMMIT');
				return value;
			} catch (error) {
				db.exec('ROLLBACK');
				throw error;
			}
		}
	};
	const core = createCoreHandlers(driver, () => {
		throw Error('offline');
	}) as any;
	const workspace = {
		// As database.worker.ts dispatches: rows unwraps its view and returns records.
		async request(method: string, args: any) {
			requests.push(method);
			return method === 'rows'
				? (await core.rows(args.view)).map((row: { record: Row }) => row.record)
				: core[method](args);
		}
	} as any;
	return { db, workspace, requests };
}

describe('reference labels', () => {
	it('labels every reference on a page with one core read per 200 targets', async () => {
		const { workspace, requests } = wideWorkspace(60);
		const rows: Row[] = await workspace.request('rows', { view: { table: 'wide', limit: 50 } });
		requests.length = 0;
		const labels = await referenceLabels(workspace, refs, rows, new Set(['targets']));
		const targets = new Set(
			rows.flatMap((row: Row) =>
				refs.flatMap((p) => (p.type === 'ref' ? [row[p.col]] : JSON.parse(String(row[p.col]))))
			)
		);
		expect(Object.keys(labels)).toHaveLength(targets.size);
		expect(labels[JSON.stringify(['targets', 'target-7'])]).toBe('Target 7');
		expect(requests).toEqual(Array(Math.ceil(targets.size / 200)).fill('mentionLabels'));
	});

	it('splits more than 200 distinct targets into reads of 200', async () => {
		const { workspace, requests } = wideWorkspace(1);
		const rows = Array.from({ length: 250 }, (_, i) => ({ id: `r${i}`, a: `target-${i + 1}` }));
		const labels = await referenceLabels(workspace, refs, rows, new Set(['targets']));
		expect(Object.keys(labels)).toHaveLength(250);
		expect(requests).toEqual(['mentionLabels', 'mentionLabels']);
	});

	it('leaves missing, trashed, malformed and uncatalogued targets unlabeled', async () => {
		const { db, workspace } = wideWorkspace(1);
		db.exec("UPDATE targets SET deleted_at='2026-01-01T00:00:00.000Z' WHERE id='target-3'");
		const row = {
			id: 'x',
			a: 'target-2',
			b: 'target-3',
			c: 'missing',
			d: 'not json',
			e: '["target-9"]'
		};
		const labels = await referenceLabels(workspace, refs, [row], new Set(['targets']));
		expect(labels).toEqual({
			[JSON.stringify(['targets', 'target-2'])]: 'Target 2',
			[JSON.stringify(['targets', 'target-9'])]: 'Target 9'
		});
		expect(await referenceLabels(workspace, refs, [row], new Set())).toEqual({});
	});

	it('opens a 10,000-row table with wide text and five reference columns within budget', async () => {
		const { workspace, requests } = wideWorkspace();
		const started = performance.now();
		// A filtered, sorted page reads the whole table, like a saved view without an index.
		const found = await workspace.request('rows', {
			view: {
				table: 'wide',
				filters: [{ column: 'b', op: 'ne', value: 'target-1' }],
				sort: [{ column: 'title', direction: 'desc' }],
				limit: 50
			}
		});
		const firstRows = performance.now() - started;
		const labels = await referenceLabels(workspace, refs, found, new Set(['targets']));
		const total = performance.now() - started;
		console.log(
			`webTableOpen first_rows_ms=${firstRows.toFixed(1)} labelled_ms=${total.toFixed(1)}`
		);
		expect(found).toHaveLength(50);
		expect(Object.keys(labels).length).toBeGreaterThan(0);
		expect(requests).toEqual(['rows', 'mentionLabels']);
		expect(firstRows).toBeLessThan(200);
		expect(total).toBeLessThan(1000);
	});
});
