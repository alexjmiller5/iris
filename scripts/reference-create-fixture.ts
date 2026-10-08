// Synthetic people/companies/meetings workspace for the native reference-create UI tests.
// Usage: bun scripts/reference-create-fixture.ts <out.sqlite>
import { Database } from 'bun:sqlite';
import { readFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

const out = process.argv[2];
if (!out) throw new Error('Usage: bun scripts/reference-create-fixture.ts <out.sqlite>');
await rm(out, { force: true });
const db = new Database(out);
let finish: (reply: { value?: unknown; error?: string }) => void = () => {};
const context = {
	LifeSql: {
		all: (sql: string, params: (string | number | null)[]) => db.query(sql).all(...params),
		run: (sql: string, params: (string | number | null)[]) => db.query(sql).run(...params).changes,
		begin: () => db.exec('BEGIN IMMEDIATE'),
		commit: () => db.exec('COMMIT'),
		rollback: () => db.exec('ROLLBACK')
	},
	__lifeYield: (callback: () => void) => queueMicrotask(callback),
	__lifeFinish: (_id: number, json: string) => finish(JSON.parse(json))
};
const core = await readFile(
	resolve(import.meta.dir, '../packages/LifeKit/Sources/LifeKit/Resources/life-core.js'),
	'utf8'
);
runInNewContext(core, context);
const native = (context as any).LifeNative;
const request = (method: string, args: object = {}) =>
	new Promise<any>((resolve, reject) => {
		finish = (reply) => (reply.error ? reject(new Error(reply.error)) : resolve(reply.value));
		native.request(1, method, JSON.stringify(args));
	});

await request('sample');
const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), deleted_at TEXT, hub_at TEXT`;
for (const [name, columns] of [
	['people', 'name TEXT, role TEXT, email TEXT'],
	['companies', 'name TEXT, domain TEXT'],
	['meetings', 'title TEXT, host TEXT, attendees TEXT, company TEXT']
]) {
	const ddl = `CREATE TABLE ${name} (${system}, ${columns})`;
	db.exec(ddl);
	db.query('INSERT INTO _schema_log (ddl) VALUES (?)').run(ddl);
}
db.exec(`INSERT INTO catalog_tables (id,kind,display,purpose) VALUES
 ('people','table','name','Synthetic people'),('companies','table','name','Synthetic companies'),
 ('meetings','table','title','Synthetic meetings')`);
const property = db.query(
	'INSERT INTO catalog_properties (id,tbl,col,label,type,required,default_value,options,ref_table,sort) VALUES (?,?,?,?,?,?,?,?,?,?)'
);
for (const row of [
	['people', 'name', 'Name', 'text', 1, null, null, null, 0],
	['people', 'role', 'Role', 'select', 0, 'Friend', '[{"v":"Friend"},{"v":"Colleague"}]', null, 1],
	['people', 'email', 'Email', 'email', 0, null, null, null, 2],
	['companies', 'name', 'Name', 'text', 1, null, null, null, 0],
	['companies', 'domain', 'Domain', 'text', 1, null, null, null, 1],
	['meetings', 'title', 'Title', 'text', 1, null, null, null, 0],
	['meetings', 'host', 'Host', 'ref', 0, null, null, 'people', 1],
	['meetings', 'attendees', 'Attendees', 'multi_ref', 0, null, null, 'people', 2],
	['meetings', 'company', 'Company', 'ref', 0, null, null, 'companies', 3]
] as const)
	property.run(`${row[0]}.${row[1]}`, ...row);
const ada = await request('write', { table: 'people', patch: { name: 'Ada Lovelace', role: 'Colleague' } });
const grace = await request('write', { table: 'people', patch: { name: 'Grace Hopper' } });
await request('write', {
	table: 'meetings',
	patch: { title: 'Planning sync', host: ada.id, attendees: [grace.id] }
});
db.close();
