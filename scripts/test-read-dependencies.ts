// Real OPFS/SQLite compiler checks: dropping a dependency or stepping an inspected
// statement must fail these assertions. Production dispatch has no SQL test seam.
import { chromium, expect } from '@playwright/test';
import { disposableOrigin } from './test-origin';
import { resolve } from 'node:path';

const url = process.env.LIFE_UI_TEST_URL ?? 'http://life-ui-markdown.localhost:5198/workspace?review';
const origin = disposableOrigin(url);
const source=process.argv[2];
if(!source)throw Error('Provide the life-data checkout for the shared adapter fixture');
const fixture=await Bun.file(resolve(source,'tests/fixtures/read-dependencies.json')).json();
const browser = await chromium.connectOverCDP(process.env.LIFE_UI_TEST_CDP ?? 'http://127.0.0.1:9222');
try {
  const page = browser.contexts().flatMap(c => c.pages()).find(p => p.url() === url);
  if (!page) throw Error('Open the dedicated dependency fixture page first.');
  await page.setViewportSize({width:1280,height:960});
  await page.goto(new URL('/',url).href);
  const cdp=await page.context().newCDPSession(page);
  await cdp.send('Storage.clearDataForOrigin',{origin,storageTypes:'all'});
  await cdp.detach();
  await page.context().route(`${origin}/src/lib/database.worker.ts*`,async route=>{
    const response=await route.fetch();
    const original=await response.text();
    const body=original.replace('switch (method) {',`switch (method) {
      case '__test_dependencies': return db.readDependencies ? db.readDependencies(args.statements,args.context ?? {ownedTempTables:[]}) : null;
      case '__test_run': return db.run(args.sql,args.params);
      case '__test_all': return db.all(args.sql,args.params);
      case '__test_ticks': return scope.dependencyTicks || 0;
      case '__test_function':
        sqlite.create_function(connection,'dependency_tick',0,SQLite.SQLITE_UTF8,0,
          context=>sqlite.result(context,scope.dependencyTicks=(scope.dependencyTicks || 0)+1));
        return null;`);
    if(body===original)throw Error('Worker seam not found.');
    await route.fulfill({response,body});
  });
  await page.goto(url);
  await page.evaluate(async()=>{
    const {WorkspaceDatabase}=await import('/src/lib/database.ts');
    (window as any).dependencyProbe=new WorkspaceDatabase();
    await (window as any).dependencyProbe.request('open',{demo:false});
  });
  await page.context().unroute(`${origin}/src/lib/database.worker.ts*`);
  async function probe(method:string,args:Record<string,unknown>={}){
    return page.evaluate(async({method,args})=>{
      try{return {ok:true,value:await (window as any).dependencyProbe.request(method,args)};}
      catch(error:any){return {ok:false,message:error.message};}
    },{method,args});
  }
  const run=async(sql:string)=>expect((await probe('__test_run',{sql})).ok).toBe(true);
  const deps=async(statements:{sql:string,params?:unknown[]}[],ownedTempTables:string[]=[])=>probe('__test_dependencies',{statements,context:{ownedTempTables}});
  await run('CREATE TABLE widgets(id TEXT PRIMARY KEY,value TEXT); CREATE TABLE labels(id TEXT,value TEXT); CREATE VIEW widget_labels AS SELECT w.id,l.value FROM widgets w JOIN labels l ON l.id=w.id; INSERT INTO widgets VALUES (\'one\',\'[]\')');
  expect(await deps([{sql:'SELECT value FROM widgets WHERE id=?',params:['one']}])).toEqual({ok:true,value:{tables:['widgets']}});
  expect(await deps([{sql:'SELECT * FROM widget_labels'}])).toEqual({ok:true,value:{tables:['labels','widgets']}});
  expect(await deps([{sql:'SELECT count(*) FROM widgets'},{sql:'SELECT EXISTS(SELECT 1 FROM labels)'}])).toEqual({ok:true,value:{tables:['labels','widgets']}});
  expect(await deps([{sql:'SELECT 1 /* widgets is only a comment */'}])).toEqual({ok:true,value:{tables:[]}});
  console.log('PASS: compiler reads include ordinary tables, view dependencies and columnless reads');
  await run('CREATE TABLE "Ä"(value TEXT); CREATE TABLE "ä"(value TEXT)');
  expect(await deps([{sql:'SELECT * FROM "Ä"'}])).toEqual({ok:true,value:{tables:['Ä']}});
  expect(await deps([{sql:'SELECT * FROM "ä"'}])).toEqual({ok:true,value:{tables:['ä']}});
  console.log('PASS: dependency identity follows SQLite ASCII-only case folding');


  expect((await probe('__test_function')).ok).toBe(true);
  expect(await deps([{sql:'SELECT dependency_tick() FROM widgets'}])).toEqual({ok:true,value:{tables:['widgets']}});
  expect((await probe('__test_ticks')).value).toBe(0);
  expect((await probe('__test_all',{sql:'SELECT dependency_tick() AS value FROM widgets'})).value).toEqual([{value:1}]);
  console.log('PASS: dependency inspection prepares without executing statements or functions');

  for(const sql of ['DELETE FROM widgets','SELECT 1; SELECT 2','PRAGMA foreign_keys=OFF','SELECT missing FROM widgets'])
    expect((await deps([{sql}])).ok,sql).toBe(false);
  expect((await probe('__test_all',{sql:'SELECT * FROM widgets'})).value).toEqual([{id:'one',value:'[]'}]);
  expect(await deps([{sql:'SELECT * FROM widgets'}])).toEqual({ok:true,value:{tables:['widgets']}});
  console.log('PASS: invalid or non-read SQL rejects and restores the ordinary adapter');

  for(const sql of ['SELECT * FROM json_each(\'[1,2]\')','SELECT * FROM widgets,json_each(widgets.value)']) {
    const tables=sql.includes('widgets')?['widgets']:[];
    expect(await deps([{sql}]),sql).toEqual({ok:true,value:{tables}});
  }
  console.log('PASS: built-in JSON iterators retain input-table dependencies');
  await run('CREATE TEMP TABLE _core_write_before AS SELECT * FROM widgets WHERE 0');
  const invariant = {sql: `WITH changed AS (SELECT * FROM main.widgets WHERE id=? EXCEPT SELECT * FROM temp._core_write_before),
    before AS (SELECT * FROM temp._core_write_before WHERE id IN (SELECT id FROM changed)), now AS (SELECT ? AS ts)
    SELECT * FROM (SELECT id FROM changed WHERE value='invalid') LIMIT 1`,params:['one','2026-01-01T00:00:00.000Z']};
  expect(await deps([invariant],['_core_write_before'])).toEqual({ok:true,value:{tables:['widgets']}});
  expect(await deps([invariant])).toEqual({ok:true,value:null});
  await run('DROP TABLE temp._core_write_before');
  expect(await deps([{sql:'SELECT 1'}],['_core_write_before'])).toEqual({ok:true,value:null});
  console.log('PASS: core-owned temporary snapshots require explicit current-transaction ownership');


  await run('CREATE TEMP TABLE unrelated(value TEXT)');
  expect(await deps([{sql:'SELECT * FROM widgets'}])).toEqual({ok:true,value:null});
  await run('DROP TABLE temp.unrelated');
  await run("ATTACH ':memory:' AS extra");
  expect(await deps([{sql:'SELECT * FROM widgets'}])).toEqual({ok:true,value:null});
  await run('DETACH extra');
  await run('CREATE VIRTUAL TABLE search_docs USING fts5(body)');
  for(const sql of ['SELECT * FROM search_docs','SELECT * FROM search_docs_data','SELECT * FROM pragma_table_info(\'widgets\')','SELECT * FROM sqlite_schema','SELECT * FROM _sync_state','SELECT * FROM _schema_log'])
    expect(await deps([{sql}]),sql).toEqual({ok:true,value:null});
  expect(await deps([{sql:'SELECT * FROM widgets'}])).toEqual({ok:true,value:{tables:['widgets']}});
  console.log('PASS: unsupported namespaces and storage dependencies fail closed without blocking unrelated virtual tables');

  for(const scenario of fixture.cases) {
    await run('BEGIN IMMEDIATE');
    try {
      // Core initialization created this name; the fixture owns its own version
      // inside a transaction that is always rolled back before the next case.
      await run('DROP TABLE _core_state; DROP TABLE _sync_state; DROP TABLE _schema_log');
      for(const sql of [...fixture.setup,...(scenario.setup??[])]) await run(sql);
      const result=await deps(scenario.statements,fixture.context.ownedTempTables);
      if(scenario.error) expect(result.ok,scenario.name).toBe(false);
      else {
        const value=result.value && {tables:[...result.value.tables].sort()};
        const expected=scenario.expected && {tables:[...scenario.expected.tables].sort()};
        expect({ok:result.ok,value},scenario.name).toEqual({ok:true,value:expected});
      }
      console.log(`PASS: shared fixture - ${scenario.name}`);
    } finally {
      await run('ROLLBACK');
      await probe('__test_run',{sql:'DETACH other'});
    }
  }

}finally{
  const page=browser.contexts().flatMap(c=>c.pages()).find(p=>p.url()===url);
  await page?.evaluate(()=>(window as any).dependencyProbe?.close()).catch(()=>{});
  await page?.reload().catch(()=>{});
  await browser.close();
}
