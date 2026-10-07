import { qident } from '../packages/core/client.js';
import type { SqlDriver, Value } from '../packages/core/index.d.ts';
import defaults from '../packages/core/schema/view-defaults.json';
import viewStorage from '../packages/core/schema/saved-views.json';
import pinStorage from '../packages/core/schema/sidebar-pins.json';
import type { Row } from '../packages/core/client.js';

/** Only the host's explicitly app-owned local/demo database may call this.
 * Ordinary replicas receive the operator's logged schema through sync. */
export async function prepareLocalViews(db: SqlDriver): Promise<boolean> {
  const views = await prepareLocalTable(db, viewStorage);
  const preferred = await prepareLocalTable(db, defaults);
  return views || preferred;
}
export const prepareLocalPins = (db: SqlDriver) => prepareLocalTable(db, pinStorage);

export async function prepareLocalTable(db: SqlDriver, storage: {ddl:string[];table:Row;properties:Row[]}): Promise<boolean> {
  return db.transaction(async () => {
    // A name collision is user data, even when only its catalog entry remains.
    // Do not adopt, rewrite or repair it, or change any accompanying metadata.
    const tableID=String(storage.table.id);
    const propertyIDs=storage.properties.map(row=>String(row.id));
    if ((await db.all("SELECT name FROM main.sqlite_master WHERE name IN (?,?)",[tableID,`${tableID}_updated_at`])).length
      || (await db.all("SELECT id FROM catalog_tables WHERE id=?",[tableID])).length
      || (await db.all(`SELECT id FROM catalog_properties WHERE tbl=? OR id IN (${propertyIDs.map(()=>'?').join(',')})`,[tableID,...propertyIDs])).length) return false;
    const columns = new Set((await db.all('PRAGMA main.table_info(catalog_properties)')).map(row => row.name));
    const ddl = [
      ...['source', 'source_ref'].filter(column => !columns.has(column)).map(column => `ALTER TABLE catalog_properties ADD COLUMN ${qident(column)} TEXT`),
      ...storage.ddl,
    ];
    for (const statement of ddl) {
      await db.run(statement);
      await db.run('INSERT INTO _schema_log (ddl) VALUES (?)', [statement]);
    }
    for (const [table, records] of [['catalog_tables', [storage.table]], ['catalog_properties', storage.properties]] as const) {
      for (const row of records) {
        const keys = Object.keys(row);
        await db.run(`INSERT INTO ${qident(table)} (${keys.map(qident).join(',')}) VALUES (${keys.map(() => '?').join(',')})`, Object.values(row) as Value[]);
      }
    }
    return true;
  });
}
