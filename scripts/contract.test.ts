import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import * as core from '../packages/core/client.js';
import type { Database } from 'bun:sqlite';

const root = resolve(import.meta.dir, '..');
test('vendored contract generates the exact Swift and TypeScript consumed by both hosts', async () => {
  const { generateContract } = await import('../packages/core/contract/generate-core-contract.ts');
  const contract = JSON.parse(await readFile(resolve(root, 'packages/core/contract/core.json'), 'utf8'));
  const output = generateContract(contract);
  expect(core.CORE_CONTRACT_HASH).toBe(output.hash);
  expect(await readFile(resolve(root, 'packages/core/contract.generated.ts'), 'utf8')).toBe(output.typescript);
  expect(await readFile(resolve(root, 'packages/IrisKit/Sources/IrisExtensionSupport/Generated/CoreContract.generated.swift'), 'utf8')).toBe(output.swift);
});

async function withNative(body: (request: (method: string, args?: object) => Promise<unknown>, db: Database) => Promise<void>) {
  const { Database } = await import('bun:sqlite');
  const { runInNewContext } = await import('node:vm');
  const db = new Database(':memory:');
  try {
    let finish: (reply: { value?: unknown; error?: string }) => void = () => {};
    const context = {
      IrisSql: {
        all: (sql: string, params: (string | number | null)[]) => db.query(sql).all(...params),
        run: (sql: string, params: (string | number | null)[]) => db.query(sql).run(...params).changes,
        begin: () => db.exec('BEGIN IMMEDIATE'), commit: () => db.exec('COMMIT'), rollback: () => db.exec('ROLLBACK'),
      },
      __irisYield: (callback: () => void) => queueMicrotask(callback),
      __irisFinish: (_id: number, json: string) => finish(JSON.parse(json)),
    };
    const script = await readFile(process.env.IRIS_TEST_CORE_PATH ?? resolve(root, 'packages/IrisKit/Sources/IrisKit/Resources/soma-core.js'), 'utf8');
    runInNewContext(script, context);
    const native = (context as typeof context & { IrisNative: { contractHash: string; request(id: number, method: string, json: string): void } }).IrisNative;
    expect(native.contractHash).toBe(core.CORE_CONTRACT_HASH);
    const request = (method: string, args: object = {}) => new Promise<unknown>((resolve, reject) => {
      finish = reply => reply.error ? reject(new Error(reply.error)) : resolve(reply.value);
      native.request(1, method, JSON.stringify(args));
    });
    await body(request, db);
  } finally { db.close(); }
}

test('native JSON dispatch uses the same generated methods and row results', () => withNative(async request => {
  await request('sample');
  const rows = await request('rows', { table: 'notes', filters: [{ column: 'title', op: 'contains', value: 'place' }], sort: [{ column: 'title', direction: 'desc' }], limit: 1 }) as core.WorkspaceRow[];
  expect(rows.map(row => row.label)).toEqual(['A place to start']);
  expect(await request('rows', { table: 'notes', filters: [{ column: 'id', op: 'eq', value: rows[0].record.id }] })).toEqual(rows);
  expect(await request('options', { table: 'notes', column: 'status' })).toEqual(['Draft', 'Ready']);
  await expect(request('toString')).rejects.toThrow('Unknown workspace operation');
  await expect(request('rows', { table: 'notes', offset: -1 })).rejects.toThrow('nonnegative');
}));

test('an app-owned sample can save and reopen a named view through the shared contract', () => withNative(async request => {
  await request('sample');
  expect(await request('listViews', {table:'notes'})).toEqual({views:[],unavailable:null});
  const definition: core.SavedViewDefinition = {version:1,columns:['title'],filters:[{column:'status',op:'eq',value:'Draft'}],sort:[{column:'title',direction:'desc'}]};
  const saved = await request('saveView', {table:'notes',name:'Draft notes',definition}) as core.SavedViewRecord;
  expect(saved.unavailable).toBeNull();
  const listed = await request('listViews',{table:'notes'}) as core.SavedViewList;
  expect(listed.views.map(view=>({id:view.id,name:view.name,definition:view.definition}))).toEqual([{id:saved.id,name:'Draft notes',definition}]);
  const rows=await request('rows',{...saved.view,columns:undefined}) as core.WorkspaceRow[];
  expect(rows.map(row=>row.label)).toEqual(['A place to start']);
}));


test('local setup backfills an older app-owned workspace once without changing notes', () => withNative(async (request, db) => {
  await request('sample');
  // Model the previous local app schema, before saved views existed.
  db.exec('DROP TRIGGER IF EXISTS views_updated_at; DROP TABLE IF EXISTS views');
  db.query("DELETE FROM catalog_tables WHERE id='views'").run();
  db.query("DELETE FROM catalog_properties WHERE tbl='views'").run();
  const notes=db.query('SELECT * FROM notes').all();
  expect(await request('prepareLocalViews')).toBe(true);
  expect(await request('listViews',{table:'notes'})).toEqual({views:[],unavailable:null});
  const log=db.query('SELECT * FROM _schema_log').all();
  expect(await request('prepareLocalViews')).toBe(false);
  expect(db.query('SELECT * FROM _schema_log').all()).toEqual(log);
  expect(db.query('SELECT * FROM notes').all()).toEqual(notes);
}));

for(const collision of ['table','catalog'] as const) test(`local setup preserves a conflicting ${collision} instead of adopting it`, () => withNative(async (request, db) => {
  await request('sample');
  db.exec('DROP TRIGGER IF EXISTS views_updated_at; DROP TABLE IF EXISTS views');
  db.query("DELETE FROM catalog_tables WHERE id='views'").run();
  db.query("DELETE FROM catalog_properties WHERE tbl='views'").run();
  if(collision==='table') db.exec("CREATE TABLE views (id TEXT, payload TEXT); INSERT INTO views VALUES ('foreign','keep me')");
  else db.exec("INSERT INTO catalog_tables(id,kind,display) VALUES ('views','table','payload')");
  const schema=db.query('SELECT type,name,sql FROM sqlite_master').all();
  const catalog=db.query('SELECT * FROM catalog_tables').all();
  const props=db.query('SELECT * FROM catalog_properties').all();
  const log=db.query('SELECT * FROM _schema_log').all();
  expect(await request('prepareLocalViews')).toBe(false);
  expect(db.query('SELECT type,name,sql FROM sqlite_master').all()).toEqual(schema);
  expect(db.query('SELECT * FROM catalog_tables').all()).toEqual(catalog);
  expect(db.query('SELECT * FROM catalog_properties').all()).toEqual(props);
  expect(db.query('SELECT * FROM _schema_log').all()).toEqual(log);
}));


test('local saved-view setup rolls schema and catalog back together after a metadata failure', () => withNative(async (request, db) => {
  await request('sample');
  db.exec('DROP TRIGGER views_updated_at; DROP TABLE views');
  db.query("DELETE FROM catalog_tables WHERE id='views'").run();
  db.query("DELETE FROM catalog_properties WHERE tbl='views'").run();
  db.exec("CREATE TRIGGER reject_view BEFORE INSERT ON catalog_tables WHEN NEW.id='views' BEGIN SELECT RAISE(ABORT, 'fixture metadata failure'); END");
  const schema=db.query('SELECT type,name,sql FROM sqlite_master').all();
  const log=db.query('SELECT * FROM _schema_log').all();
  await expect(request('prepareLocalViews')).rejects.toThrow();
  expect(db.query('SELECT type,name,sql FROM sqlite_master').all()).toEqual(schema);
  expect(db.query('SELECT * FROM _schema_log').all()).toEqual(log);
  expect(db.query("SELECT * FROM catalog_properties WHERE tbl='views'").all()).toEqual([]);
}));

test('native rejection dispatch preserves canonical payloads, exact IDs and bounded pages without initialization', () => withNative(async (request, db) => {
  expect(await request('rejections')).toEqual({ rejections: [], nextOffset: null });
  expect(db.query('SELECT name FROM sqlite_master').all()).toEqual([]);
  db.exec('CREATE TABLE _core_rejected(tbl TEXT,row_id TEXT,row TEXT NOT NULL,errors TEXT NOT NULL,PRIMARY KEY(tbl,row_id))');
  const records = ['e\u0301', 'é'].map(id => ({ table: 'items', rowID: id, submitted: { id, body: 'Fixture body' }, errors: [{ id, message: 'Rejected', future: { detail: ['value', null] } }] }));
  for (const entry of records) db.query('INSERT INTO _core_rejected VALUES (?,?,?,?)').run(entry.table, entry.rowID, JSON.stringify(entry.submitted), JSON.stringify(entry.errors));
  expect(await request('rejections', { limit: 1 })).toEqual({ rejections: [records[0]], nextOffset: 1 });
  expect(await request('rejections', { limit: 1, offset: 1 })).toEqual({ rejections: [records[1]], nextOffset: null });
  db.query('UPDATE _core_rejected SET errors=? WHERE row_id=?').run('invalid fixture JSON', 'é');
  await expect(request('rejections', { limit: 1 })).rejects.toThrow('Invalid stored rejection data');
  expect(db.query('SELECT count(*) AS n FROM _core_rejected').get()).toEqual({ n: 2 });
}));


test('local defaults use real core persistence and leave all named views intact', () => withNative(async (request, db) => {
  await request('sample');
  const saved = await request('saveView', {table:'notes',name:'Chosen',definition:{version:1}}) as core.SavedViewRecord;
  const before=db.query('SELECT * FROM views').all();
  const initial=await request('getViewDefault',{table:'notes'}) as core.ViewDefault;
  expect(initial.unavailable).toBeNull();
  const preferred=await request('setViewDefault',{table:'notes',viewId:saved.id,expectedUpdatedAt:null}) as core.ViewDefault;
  expect(preferred.view?.id).toBe(saved.id);
  expect(db.query('SELECT * FROM views').all()).toEqual(before);
}));
test('local related preferences use their own canonical store without changing table defaults',()=>withNative(async(request,db)=>{
 await request('sample');
 const view=await request('saveView',{table:'notes',name:'Related fixture',definition:{version:1}}) as core.SavedViewRecord;
 expect((await request('getRelatedViewDefault',{table:'notes'}) as core.ViewDefault).unavailable).toBeNull();
 const related=await request('setRelatedViewDefault',{table:'notes',viewId:view.id,expectedUpdatedAt:null}) as core.ViewDefault;
 expect(related.viewId).toBe(view.id);
 expect((await request('getViewDefault',{table:'notes'}) as core.ViewDefault).viewId).toBeNull();
 expect(db.query('SELECT view_id FROM related_view_defaults').get()).toEqual({view_id:view.id});
}));
test('local pins are provisioned from the canonical manifest and written through native dispatch',()=>withNative(async(request,db)=>{
 await request('sample');
 expect(await request('prepareLocalPins')).toBe(false);
 const state=await request('listSidebarPins') as core.SidebarPinList;expect(state.unavailable).toBeNull();
 const pinned=await request('pinTable',{table:'notes',expectedUpdatedAt:null}) as core.SidebarPinList;
 expect(pinned.pins.map(pin=>pin.tbl)).toEqual(['notes']);
 expect(db.query('SELECT tbl,position FROM sidebar_pins').all()).toEqual([{tbl:'notes',position:0}]);
}));
test('local pins never adopt a foreign table or remaining catalog identity',()=>withNative(async(request,db)=>{
 await request('sample');db.exec('DROP TRIGGER sidebar_pins_updated_at; DROP TABLE sidebar_pins; CREATE TABLE sidebar_pins(content TEXT)');
 const before=db.query('SELECT type,name,sql FROM sqlite_master').all();
 expect(await request('prepareLocalPins')).toBe(false);
 expect(db.query('SELECT type,name,sql FROM sqlite_master').all()).toEqual(before);
}));

test('native catalog mutations preserve descriptions and logs while unbound rule writes fail closed', () => withNative(async (request, db) => {
  await request('sample');
  const catalog=await request('catalog') as core.Catalog;
  const property=catalog.properties.find(p=>p.tbl==='notes'&&p.col==='status')!;
  const args={table:'notes',column:'status',expectedUpdatedAt:property.updated_at??null,fields:{options:[{v:'Draft',d:'Work in progress'},{v:'Ready',d:'Reviewed'}]}};
  const saved=await request('saveCatalogProperty',args) as core.Property;
  expect(saved.options?.[0].d).toBe('Work in progress');expect(saved.updated_at).toBeString();
  await expect(request('saveCatalogProperty',args)).rejects.toThrow(/changed/);
  await request('saveCatalogRule',{table:'notes',id:'draft-only',expectedUpdatedAt:null,fields:{scope:'table',kind:'invariant',text:'Keep this synthetic record in draft.',sql:"SELECT id FROM changed WHERE status='Ready'",enforce:1}});
  const row=(await request('rows',{table:'notes'}) as core.WorkspaceRow[])[0].record;
  // This sample is deliberately unbound: creating a rule does not invent replication trust.
  await expect(request('write',{table:'notes',patch:{id:row.id,status:'Ready'},expectedUpdatedAt:row.updated_at})).rejects.toThrow('Replication coverage is unverified');
  expect(db.query('SELECT text FROM catalog_rules WHERE id=?').get('draft-only')).toEqual({text:'Keep this synthetic record in draft.'});
  expect(db.query('SELECT status FROM notes WHERE id=?').get(String(row.id))).toEqual({status:row.status});
  expect(db.query('SELECT action FROM catalog_log').all()).toEqual([{action:'set'},{action:'set'}]);
}));

test('local catalog audit setup backfills once and preserves records', () => withNative(async(request, db) => {
  await request('sample');
  db.exec('DROP TRIGGER catalog_log_updated_at; DROP TABLE catalog_log');
  db.query("DELETE FROM catalog_tables WHERE id='catalog_log'").run();
  db.query("DELETE FROM catalog_properties WHERE tbl='catalog_log'").run();
  const notes=db.query('SELECT * FROM notes').all();
  expect(await request('prepareLocalCatalog')).toBe(true);
  const schema=db.query('SELECT ddl FROM _schema_log').all();
  expect(await request('prepareLocalCatalog')).toBe(false);
  expect(db.query('SELECT ddl FROM _schema_log').all()).toEqual(schema);
  expect(db.query('SELECT * FROM notes').all()).toEqual(notes);
}));

test('local catalog audit setup leaves foreign storage untouched', () => withNative(async(request, db) => {
  await request('sample');
  db.exec('DROP TRIGGER catalog_log_updated_at; DROP TABLE catalog_log; CREATE TABLE catalog_log(content TEXT)');
  db.query("INSERT INTO catalog_log VALUES ('foreign fixture')").run();
  const before=db.query('SELECT type,name,sql FROM sqlite_master').all();
  expect(await request('prepareLocalCatalog')).toBe(false);
  expect(db.query('SELECT type,name,sql FROM sqlite_master').all()).toEqual(before);
  expect(db.query('SELECT * FROM catalog_log').all()).toEqual([{content:'foreign fixture'}]);
}));
