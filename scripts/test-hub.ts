import { resolve } from 'node:path';

// Real Worker, synthetic SQLite. Explicit source path keeps this optional
// integration harness usable without a prescribed sibling checkout layout.
const source=process.argv[2];
if(!source)throw new Error('Usage: bun scripts/test-hub.ts <life-data-checkout>');
const {default:worker}=await import(resolve(source,'worker/src/index.js'));
const {D1Shim}=await import(resolve(source,'worker/test/d1shim.js'));
const db=new D1Shim();
db.db.exec('CREATE TABLE _schema_log(id INTEGER PRIMARY KEY,applied_at TEXT,ddl TEXT)');
const system=`id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT`;
for(const [name,columns] of Object.entries({
  widgets:'title TEXT, body TEXT, quantity INTEGER',
  catalog_tables:'kind TEXT,display TEXT,purpose TEXT',
  catalog_properties:'tbl TEXT,col TEXT,label TEXT,sort INTEGER,type TEXT,required INTEGER,default_value TEXT,options TEXT,options_sql TEXT,min_items INTEGER,max_items INTEGER,pattern TEXT,ref_table TEXT,derived_by TEXT,inputs TEXT,immutable INTEGER,deprecated INTEGER,description TEXT',
  catalog_rules:'scope TEXT,tbl TEXT,col TEXT,kind TEXT,text TEXT,sql TEXT,cmd TEXT,enforce INTEGER',
  history:'tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT',
})){
  const ddl=`CREATE TABLE "${name}" (${system},${columns})`;
  db.db.exec(ddl);
  db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z',ddl);
}
db.db.exec(`INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('widgets','table','title','Synthetic integration workspace');
INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required) VALUES ('widgets.title','widgets','title','Title',0,'text',1),('widgets.body','widgets','body','Body',1,'markdown',0),('widgets.quantity','widgets','quantity','Quantity',2,'int',0);
INSERT INTO widgets(id,title,body,quantity) VALUES ('fixture-record','Fixture record','# From the hub',4);`);
const port=Number(process.env.LIFE_UI_TEST_HUB_PORT??5200);
const server=Bun.serve({hostname:'127.0.0.1',port,fetch(request){
  return worker.fetch(request,{DB:db,HUB_TOKEN:'fixture',CORS_ORIGINS:process.env.LIFE_UI_TEST_ORIGIN??'http://127.0.0.1:5197'},{waitUntil(p:Promise<unknown>){void p.catch(()=>{});}});
}});
console.log(`Synthetic hub listening at ${server.url}`);
