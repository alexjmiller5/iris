import { describe, expect, it } from 'vitest';
import { DatabaseSync } from 'node:sqlite';
import { createCoreHandlers, type Property, type Row } from 'life-ui-core/client';
import { recordPatch } from './record-grid';
import {
	commitCreation,
	creationOffer,
	creationPlan,
	creationTarget,
	startCreation,
	withReference
} from './reference-create';

const people: Property[] = [
	{ tbl: 'people', col: 'name', type: 'text', required: 1 },
	{ tbl: 'people', col: 'role', type: 'text', default_value: 'Friend' },
	{ tbl: 'people', col: 'met', type: 'text', default_value: "sql:'today'" },
	{ tbl: 'people', col: 'email', type: 'email' }
];
const companies: Property[] = [
	{ tbl: 'companies', col: 'domain', type: 'text', required: 1, sort: 1 },
	{ tbl: 'companies', col: 'name', type: 'text', required: 1, sort: 0 },
	{ tbl: 'companies', col: 'score', type: 'int', derived_by: 'http:score' }
];
const catalog = {
	tables: [
		{ id: 'people', display: 'name', readOnly: false },
		{ id: 'companies', display: 'name', readOnly: false },
		{ id: 'history', display: 'col', readOnly: true }
	] as Row[],
	properties: [...people, ...companies]
};
const host: Property = { tbl: 'meetings', col: 'host', type: 'ref', ref_table: 'people' };

/** The browser Worker's core over a synchronous node:sqlite database, with no hub. */
function localCore() {
	const db = new DatabaseSync(':memory:');
	const system = `id TEXT PRIMARY KEY NOT NULL, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT`;
	for (const [name, columns] of Object.entries({
		people: 'name TEXT, role TEXT, met TEXT, email TEXT',
		companies: 'name TEXT, domain TEXT, score INTEGER',
		catalog_tables: 'kind TEXT, display TEXT, purpose TEXT',
		catalog_properties:
			'tbl TEXT, col TEXT, label TEXT, sort INTEGER, type TEXT, required INTEGER, default_value TEXT, options TEXT, options_sql TEXT, min_items INTEGER, max_items INTEGER, pattern TEXT, ref_table TEXT, derived_by TEXT, inputs TEXT, immutable INTEGER, deprecated INTEGER, description TEXT',
		catalog_rules:
			'scope TEXT, tbl TEXT, col TEXT, kind TEXT, text TEXT, sql TEXT, cmd TEXT, enforce INTEGER',
		history: 'tbl TEXT, row_id TEXT, col TEXT, old TEXT, new TEXT, origin TEXT'
	}))
		db.exec(`CREATE TABLE ${name} (${system}, ${columns})`);
	db.exec(`INSERT INTO catalog_tables(id,kind,display) VALUES ('people','table','name'),('companies','table','name')`);
	for (const p of [...people, ...companies])
		db.prepare(
			'INSERT INTO catalog_properties(id,tbl,col,type,required,default_value,derived_by) VALUES (?,?,?,?,?,?,?)'
		).run(
			`${p.tbl}.${p.col}`,
			p.tbl!,
			p.col,
			p.type!,
			p.required ? 1 : 0,
			p.default_value ?? null,
			p.derived_by ?? null
		);
	const calls: string[] = [];
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
	const core = createCoreHandlers(
		driver,
		() => {
			calls.push('hub');
			throw Error('offline');
		},
		'test'
	) as any;
	return { db, core, calls };
}

describe('reference create-in-place', () => {
	it('offers the trimmed search text only when no loaded record has that exact name', () => {
		const loaded = [{ label: 'Ada Lovelace' }, { label: 'Grace' }];
		expect(creationOffer('  Ada  ', loaded)).toBe('Ada');
		expect(creationOffer('Ada Lovelace', loaded)).toBeNull();
		expect(creationOffer(' Grace ', loaded)).toBeNull();
		expect(creationOffer('grace', loaded)).toBe('grace');
		expect(creationOffer('   ', loaded)).toBeNull();
		expect(creationOffer('', [])).toBeNull();
	});

	it('is not offered for read-only targets or a missing, derived or deprecated display property', () => {
		expect(creationTarget(catalog, host)).toMatchObject({ table: 'people', display: 'name' });
		const target = (tables: Row[], properties = catalog.properties) =>
			creationTarget({ tables, properties }, host);
		expect(target([{ id: 'people', display: 'name', readOnly: true }])).toBeNull();
		expect(target([{ id: 'people', display: 'name', kind: 'system' }])).toBeNull();
		expect(target([{ id: 'people', display: null }])).toBeNull();
		expect(target([{ id: 'people', display: 'id' }])).toBeNull();
		expect(target([])).toBeNull();
		for (const flag of [{ derived_by: 'http:name' }, { deprecated: 1 }])
			expect(
				target(catalog.tables, [{ ...people[0], ...flag } as Property, ...people.slice(1)])
			).toBeNull();
		expect(creationTarget(catalog, { ...host, ref_table: 'history' })).toBeNull();
		expect(creationTarget(catalog, { ...host, ref_table: null })).toBeNull();
	});

	it('creates through the ordinary local writer with catalog defaults, offline', async () => {
		const { core, calls } = localCore();
		const plan = creationPlan(creationTarget(catalog, host)!, 'Ada');
		expect(plan.missing).toEqual([]);
		expect(plan.values).toEqual({ name: 'Ada', role: 'Friend', met: '', email: '' });
		const patch = recordPatch(plan.properties, plan.values, null, plan.explicit);
		expect(patch).toEqual({ name: 'Ada' });
		const stored: Row = await core.write({ table: 'people', patch });
		expect(stored).toMatchObject({ name: 'Ada', role: 'Friend', met: 'today', email: null });
		expect(typeof stored.id).toBe('string');
		expect(calls).toEqual([]);
		expect((await core.status({})).pendingUiEdits).toBe(1);
		const undo = (await core.undoStatus({})).action;
		expect(undo).toMatchObject({ table: 'people', rowId: stored.id });
		await core.undo({ receiptId: undo.receiptId });
		expect(await core.rows({ table: 'people' })).toEqual([]);
	});

	it('hands required fields other than the name to the editor, which saves through validation', async () => {
		const { core } = localCore();
		const target = creationTarget(catalog, { ...host, ref_table: 'companies' })!;
		const plan = creationPlan(target, 'Initech');
		expect(plan.missing.map((p) => p.col)).toEqual(['domain']);
		expect(plan.properties.map((p) => p.col)).toEqual(['name', 'domain']);
		await expect(
			core.write({
				table: 'companies',
				patch: recordPatch(plan.properties, plan.values, null, plan.explicit)
			})
		).rejects.toThrow();
		expect(await core.rows({ table: 'companies' })).toEqual([]);
		plan.values.domain = 'initech.example';
		plan.explicit.add('domain');
		const stored: Row = await core.write({
			table: 'companies',
			patch: recordPatch(plan.properties, plan.values, null, plan.explicit)
		});
		expect(stored).toMatchObject({ name: 'Initech', domain: 'initech.example' });
	});

	it('the hand-off and its cancel write nothing; Save appends the new id to the source', async () => {
		const { core } = localCore();
		const writes: string[] = [];
		const write = (table: string, patch: Row) => {
			writes.push(table);
			return core.write({ table, patch });
		};
		const target = creationTarget(catalog, { ...host, ref_table: 'companies' })!;
		const handoff = await startCreation(target, 'Initech', { type: 'multi_ref', raw: '["kept"]' }, write);
		expect('row' in handoff).toBe(false);
		// Cancel discards the returned plan: the source draft was never rebuilt.
		expect(writes).toEqual([]);
		expect(await core.rows({ table: 'companies' })).toEqual([]);
		if ('row' in handoff) return;
		handoff.values.domain = 'initech.example';
		handoff.explicit.add('domain');
		const saved = await commitCreation(handoff, { type: 'multi_ref', raw: '["kept"]' }, write);
		expect(saved.value).toBe(JSON.stringify(['kept', saved.row.id]));
		expect(writes).toEqual(['companies']);
	});

	it('a direct create returns the ref value; an unreadable source is never written around', async () => {
		const { core } = localCore();
		const writes: string[] = [];
		const write = (table: string, patch: Row) => {
			writes.push(table);
			return core.write({ table, patch });
		};
		const target = creationTarget(catalog, host)!;
		const created = await startCreation(target, 'Ada', { type: 'ref', raw: 'old' }, write);
		expect('row' in created && created.value).toBe('row' in created && created.row.id);
		await expect(
			startCreation(target, 'Grace', { type: 'multi_ref', raw: 'not json' }, write)
		).rejects.toThrow('cannot be read');
		expect(writes).toEqual(['people']);
	});

	it('a single reference takes the new id while multi_ref appends it once', () => {
		expect(withReference('ref', 'old-id', 'new-id')).toBe('new-id');
		expect(withReference('multi_ref', '', 'new-id')).toBe('["new-id"]');
		expect(withReference('multi_ref', '["a","b"]', 'new-id')).toBe('["a","b","new-id"]');
		expect(withReference('multi_ref', '["a","new-id"]', 'new-id')).toBe('["a","new-id"]');
		expect(withReference('multi_ref', 'not json', 'new-id')).toBeNull();
		expect(withReference('multi_ref', '{"a":1}', 'new-id')).toBeNull();
	});
});
