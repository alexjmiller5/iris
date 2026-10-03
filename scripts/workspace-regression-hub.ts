import { resolve } from 'node:path';

/** Actual service Worker with disposable, synthetic D1 state. */
export async function regressionHub(source: string, origin: string, port = 0, options: {
	wrap?: (worker: any) => any;
	env?: Record<string, unknown>;
	context?: Record<string, unknown>;
} = {}) {
	const { default: worker } = await import(resolve(source, 'worker/src/index.js'));
	const { D1Shim } = await import(resolve(source, 'worker/test/d1shim.js'));
	const db = new D1Shim();
	const auth = new D1Shim();
	const {ensureAuthReady,hashToken}=await import(resolve(source,'worker/src/auth.js'));
	await ensureAuthReady(auth);
	await auth.prepare('INSERT INTO _tokens(hash,name,scopes,label) VALUES (?,?,?,?)').bind(await hashToken('fixture'),'device:example','full','Example device').run();
	db.db.exec('CREATE TABLE _schema_log(id INTEGER PRIMARY KEY,applied_at TEXT,ddl TEXT)');
	const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT`;
	for (const [name, columns] of Object.entries({
		widgets: 'title TEXT,body TEXT,quantity INTEGER DEFAULT 42,status TEXT,tags TEXT',
		catalog_tables: 'kind TEXT,display TEXT,purpose TEXT',
		catalog_properties: 'tbl TEXT,col TEXT,label TEXT,sort INTEGER,type TEXT,required INTEGER,default_value TEXT,options TEXT,options_sql TEXT,min_items INTEGER,max_items INTEGER,pattern TEXT,ref_table TEXT,derived_by TEXT,inputs TEXT,immutable INTEGER,deprecated INTEGER,description TEXT',
		catalog_rules: 'scope TEXT,tbl TEXT,col TEXT,kind TEXT,text TEXT,sql TEXT,cmd TEXT,enforce INTEGER',
		history: 'tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT'
	})) {
		const ddl = `CREATE TABLE "${name}" (${system},${columns})`;
		db.db.exec(ddl);
		db.db.query('INSERT INTO _schema_log(applied_at,ddl) VALUES (?,?)').run('2026-01-01T00:00:00.000Z', ddl);
	}
	db.db.exec(`INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('widgets','table','title','Synthetic regression workspace');
		INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required,default_value,options,options_sql) VALUES
		('widgets.title','widgets','title','Title',0,'text',1,NULL,NULL,NULL),
		('widgets.body','widgets','body','Body',1,'markdown',0,NULL,NULL,NULL),
		('widgets.quantity','widgets','quantity','Quantity',2,'int',0,NULL,NULL,NULL),
		('widgets.status','widgets','status','Status',3,'select',0,'sql:''Dynamic''',NULL,'SELECT ''Dynamic'' AS value'),
		('widgets.tags','widgets','tags','Tags',4,'multi_select',0,NULL,'[{"v":"Fixed"}]','SELECT ''Dynamic'' AS value');
		INSERT INTO widgets(id,title,body,status,tags) VALUES
		('fixture-record','Fixture record','Original body','Dynamic','["Dynamic"]'),
		('second-record','Second record','Second body','Dynamic',NULL),
		('legacy-record','Legacy record','Legacy body','Dynamic','["Legacy","Dynamic"]');`);
	const handler = options.wrap?.(worker) ?? worker;
	const server = Bun.serve({ hostname: '127.0.0.1', port, fetch(request) {
		return handler.fetch(request, { DB: db, HUB_TOKEN: 'fixture-root', AUTH_DB: auth, CORS_ORIGINS: origin, ...options.env }, { ...options.context, waitUntil(p: Promise<unknown>) { void p.catch(() => {}); } });
	} });
	return { server, db, auth };
}

if (import.meta.main) {
	if (!process.argv[2]) throw new Error('Usage: bun scripts/workspace-regression-hub.ts <life-data-checkout>');
	const { server } = await regressionHub(process.argv[2], process.env.LIFE_UI_TEST_ORIGIN ?? 'http://life-ui-write-fixes.localhost:5196', Number(process.env.LIFE_UI_TEST_HUB_PORT ?? 5203));
	console.log(`Synthetic regression hub: ${server.url}`);
}
