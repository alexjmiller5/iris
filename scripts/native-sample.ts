import { initCore, writeRow } from '../packages/core/client.js';
import type { SqlDriver } from '../packages/core/index.d.ts';

/** Explicit synthetic workspace only. Never seed an existing database. */
export async function createSample(db: SqlDriver) {
  const existing = await db.all("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  if (existing.length) throw new Error('Sample workspace requires an empty database.');
  await db.transaction(async () => {
    await initCore(db);
    const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      deleted_at TEXT, hub_at TEXT`;
    const tables = {
      notes: 'title TEXT, status TEXT, body TEXT',
      catalog_tables: 'kind TEXT, display TEXT, purpose TEXT',
      catalog_properties: 'tbl TEXT, col TEXT, label TEXT, sort INTEGER, type TEXT, required INTEGER, default_value TEXT, options TEXT, options_sql TEXT, min_items INTEGER, max_items INTEGER, pattern TEXT, ref_table TEXT, derived_by TEXT, inputs TEXT, immutable INTEGER, deprecated INTEGER, description TEXT',
      catalog_rules: 'scope TEXT, tbl TEXT, col TEXT, kind TEXT, text TEXT, sql TEXT, cmd TEXT, enforce INTEGER',
      history: 'tbl TEXT, row_id TEXT, col TEXT, old TEXT, new TEXT, origin TEXT',
    };
    for (const [name, columns] of Object.entries(tables)) {
      const ddl = `CREATE TABLE ${name} (${system}, ${columns})`;
      await db.run(ddl);
      await db.run('INSERT INTO _schema_log (ddl) VALUES (?)', [ddl]);
    }
    await db.run("INSERT INTO catalog_tables (id,kind,display,purpose) VALUES ('notes','table','title','A sample collection for local notes.'),('history','table','col','Read-only record of edits.')");
    for (const [col, label, type, required, defaults, options, description] of [
      ['title', 'Title', 'text', 1, null, null, 'A short, descriptive title.'],
      ['status', 'Status', 'select', 0, 'Draft', JSON.stringify([{v:'Draft'},{v:'Ready'}]), 'Choose Draft or Ready.'],
      ['body', 'Body', 'markdown', 0, null, null, 'Markdown source. Formatting is preserved when you save.'],
    ] as const) {
      await db.run('INSERT INTO catalog_properties (id,tbl,col,label,type,required,default_value,options,description,sort) VALUES (?,?,?,?,?,?,?,?,?,?)',
        [`notes.${col}`, 'notes', col, label, type, required, defaults, options, description, col === 'title' ? 0 : col === 'status' ? 1 : 2]);
    }
    for (const col of ['tbl','row_id','col','old','new','origin']) {
      await db.run('INSERT INTO catalog_properties (id,tbl,col,type) VALUES (?,?,?,?)', [`history.${col}`,'history',col,'text']);
    }
  });
  await writeRow(db, 'notes', { title: 'A place to start', body: '# A place to start\n\nBrowse, write, and keep the source yours.' }, {origin:'life-ui'});
}
