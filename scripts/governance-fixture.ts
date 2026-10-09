import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Test-only transport to the owner's real Worker. No network, credentials,
// production schema, proposal implementation or alternate writer lives here.
const source = process.env.SOMA_CONTRACT_ROOT;
if (!source) throw new Error('Set SOMA_CONTRACT_ROOT to a Soma checkout containing conditional patch 9121ef6. See docs/governance-contract.md.');
const { default: worker } = await import(pathToFileURL(resolve(source, 'worker/src/index.js')).href);
const { D1Shim } = await import(pathToFileURL(resolve(source, 'worker/test/d1shim.js')).href);
export const T0 = '2025-01-01T00:00:00.000Z';
export const T1 = '2025-01-02T00:00:00.000Z';

export async function fresh() {
  const db = new D1Shim();
  const auth = new D1Shim();
  const call = async (path: string, body?: object, token = 'operator-fixture'): Promise<Response> => {
    const background: Promise<unknown>[] = [];
    const response = await worker.fetch(new Request('https://hub.test' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB: db, AUTH_DB: auth, HUB_TOKEN: 'operator-fixture' }, {
    waitUntil(promise: Promise<unknown>) { background.push(promise); },
  });
    await Promise.all(background);
    return response;
  };
  try {
    db.db.exec(`
      CREATE TABLE items(id TEXT PRIMARY KEY,name TEXT,status TEXT,qty INTEGER,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
      CREATE TABLE private_rows(id TEXT PRIMARY KEY,value TEXT);
      CREATE TABLE catalog_tables(id TEXT PRIMARY KEY,kind TEXT,deleted_at TEXT);
      CREATE TABLE catalog_properties(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,type TEXT,required INTEGER,sort INTEGER,options TEXT,options_sql TEXT,ref_table TEXT,default_value TEXT,derived_by TEXT,inputs TEXT,deleted_at TEXT);
      CREATE TABLE catalog_rules(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,kind TEXT,enforce INTEGER,scope TEXT,sql TEXT,text TEXT,deleted_at TEXT);
      CREATE TABLE history(id TEXT PRIMARY KEY,tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
      INSERT INTO catalog_tables VALUES ('items','table',NULL);
      INSERT INTO catalog_properties(id,tbl,col,type,required) VALUES ('name','items','name','text',1);
      INSERT INTO catalog_properties(id,tbl,col,type,options) VALUES ('status','items','status','select','[{"v":"open"},{"v":"closed"}]');
      INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('qty','items','qty','int');
      INSERT INTO items VALUES ('a','Original','open',1,'${T0}',NULL,'${T0}'),('b','Other','open',2,'${T0}',NULL,'${T0}');
      INSERT INTO private_rows VALUES ('hidden','keep');
    `);
    // Normal API initialization can create bookkeeping even on a failed patch.
    // These assertions concern mutation atomicity on an initialized service,
    // not a preview endpoint or an assertion that authentication is read-only.
    const catalog = await call('/v1/catalog');
    if (catalog.status !== 200) throw new Error(`Fixture catalog setup failed: ${catalog.status}`);
    const subscription = await call('/v1/subscriptions', { label: 'Fixture', start: 'now', sources: [{ table: 'items', columns: ['status'] }] });
    if (subscription.status !== 201) throw new Error(`Fixture subscription setup failed: ${subscription.status}`);
  } catch (error) { db.db.close(); auth.db.close(); throw error; }
  const rows = (table: string) => db.db.query(`SELECT * FROM "${table}" ORDER BY rowid`).all();
  return {
    db, auth, call,
    row: () => db.db.query("SELECT * FROM items WHERE id='a'").get(),
    history: () => db.db.query('SELECT col,old,new FROM history ORDER BY col').all(),
    events: () => rows('_change_events'),
    // Snapshot *all* main DB tables, including outbox/delivery bookkeeping,
    // plus temporary schema. Authentication telemetry is not asserted inert.
    state: () => ({
      tables: db.db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(({ name }: { name: string }) => ({ name, rows: rows(name) })),
      temporary: db.db.query('SELECT name,sql FROM temp.sqlite_master ORDER BY name').all(),
    }),
    patch: (extra: object = {}, token?: string) => call('/v1/rows/patch', {
      table: 'items', id: 'a', values: { status: 'closed' }, expected_revision: { updated_at: T0, hub_at: T0 }, ...extra,
    }, token),
    token: async (scopes: string): Promise<string> => {
      const response = await call('/v1/tokens/create', { name: 'fixture-consumer', scopes });
      if (response.status !== 200) throw new Error(`Fixture token setup failed: ${response.status}`);
      return (await response.json()).token;
    },
    close: () => { db.db.close(); auth.db.close(); },
  };
}
