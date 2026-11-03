import type { WorkspaceMigrationSnapshot } from './workspace-migration';
export interface SQLiteInventoryDriver {
	all(sql: string): Promise<Record<string, unknown>[]>;
	/** A real stable SQLite snapshot; caller must already have drained/retired legacy writers. */
	transaction<T>(work: () => Promise<T>): Promise<T>;
}
type Part = Pick<
	WorkspaceMigrationSnapshot,
	'database-schema' | 'database-values' | 'pending-intents'
>;
type Cell = ['null'] | ['integer' | 'real' | 'text' | 'blob', string];
const encoder = new TextEncoder();
const q = (name: string) => '"' + name.replaceAll('"', '""') + '"';
const fail = () => new Error('Complete lossless SQLite inventory is unavailable.');
const integer = (value: unknown): value is number =>
	typeof value === 'number' && Number.isSafeInteger(value);
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0;
const fold = (value: string) => value.replace(/[A-Z]/g, (c) => c.toLowerCase());
// Canonical core/src/sync.ts persists these queues in main. All other tables,
// including sync/rejected/history/coverage/search state, remain fully inventoried too.
const pendingTables = ['_core_pending', '_core_history_hold', '_core_sync_snapshot'];
function cell(type: unknown, value: unknown): Cell {
	if (type === 'null') {
		if (value !== null) throw fail();
		return ['null'];
	}
	if (type === 'integer') {
		if (typeof value !== 'string' || !/^-?(0|[1-9][0-9]*)$/.test(value)) throw fail();
		const n = BigInt(value);
		if (n < -(1n << 63n) || n > (1n << 63n) - 1n || n.toString() !== value) throw fail();
		return ['integer', value];
	}
	if (type === 'real') {
		if (typeof value !== 'number' || Number.isNaN(value)) throw fail();
		const bytes = new Uint8Array(8);
		new DataView(bytes.buffer).setFloat64(0, value, false);
		return ['real', Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')];
	}
	if (
		(type === 'text' || type === 'blob') &&
		typeof value === 'string' &&
		/^(?:[0-9A-F]{2})*$/.test(value)
	)
		return [type, value];
	throw fail();
}
/** Logical schema plus every main-table value, including virtual-table shadows
 * and internal/unsynced rows. Never uses SQL export, user-table filters or counts
 * as preservation proof. Physical schema rootpages are allocation details.
 * Bounded snapshots refuse large cells/inventories until a streaming host exists;
 * refusal leaves legacy state untouched. No copy, cleanup or migration activation.
 */
export async function collectSQLiteInventory(
	driver: SQLiteInventoryDriver,
	options: { budgetBytes?: number } = {}
): Promise<Part> {
	const limit = options.budgetBytes ?? 64 * 1024 * 1024;
	if (!Number.isSafeInteger(limit) || limit < 1 || limit > 64 * 1024 * 1024) throw fail();
	return driver.transaction(async () => {
		const out: Part = { 'database-schema': [], 'database-values': [], 'pending-intents': [] };
		let budget = 0;
		const add = (domain: keyof Part, key: string, value: unknown) => {
			const bytes = encoder.encode(JSON.stringify(value));
			budget += encoder.encode(key).length + bytes.length;
			if (budget > limit)
				throw new Error('SQLite inventory requires a streaming host for this workspace.');
			out[domain].push({ key, value: bytes });
		};
		const databases = await driver.all('PRAGMA database_list');
		if (databases.some((r) => r.name !== 'main' && r.name !== 'temp')) throw fail();
		const tables = await driver.all('PRAGMA main.table_list');
		if ((await driver.all('PRAGMA temp.table_list')).some((r) => r.name !== 'sqlite_temp_schema'))
			throw new Error('Retire temporary SQLite state before migration.');
		const schema = await driver.all(
			'SELECT type,name,tbl_name,sql FROM main.sqlite_schema ORDER BY type,name'
		);
		for (const entry of schema) {
			if (
				!['table', 'view', 'index', 'trigger'].includes(String(entry.type)) ||
				!text(entry.name) ||
				!text(entry.tbl_name) ||
				(entry.sql !== null && typeof entry.sql !== 'string')
			)
				throw fail();
			add('database-schema', JSON.stringify(['ddl', entry.type, entry.name]), [
				entry.type,
				entry.name,
				entry.tbl_name,
				entry.sql
			]);
		}
		const names = new Set<string>();
		for (const table of tables) {
			if (
				table.schema !== 'main' ||
				!text(table.name) ||
				!['table', 'virtual', 'shadow', 'view'].includes(String(table.type)) ||
				!integer(table.ncol) ||
				!integer(table.wr) ||
				![0, 1].includes(table.wr) ||
				!integer(table.strict) ||
				![0, 1].includes(table.strict)
			)
				throw fail();
			if (table.name === 'sqlite_schema') continue;
			if (table.type === 'view') {
				if (schema.filter((r) => r.type === 'view' && r.name === table.name).length !== 1)
					throw fail();
				continue;
			}
			if (
				names.has(table.name) ||
				schema.filter((r) => r.type === 'table' && r.name === table.name).length !== 1
			)
				throw fail();
			names.add(table.name);
		}
		if (schema.some((r) => r.type === 'table' && !names.has(r.name as string))) throw fail();
		for (const name of pendingTables)
			add('pending-intents', JSON.stringify([name, 'presence']), names.has(name));
		for (const table of tables
			.filter((r) => r.name !== 'sqlite_schema' && r.type !== 'view')
			.sort((a, b) => ((a.name as string) < (b.name as string) ? -1 : 1))) {
			const name = table.name as string,
				columns = await driver.all(`PRAGMA main.table_xinfo(${q(name)})`);
			if (
				columns.length !== table.ncol ||
				!columns.length ||
				new Set(columns.map((c) => fold(String(c.name)))).size !== columns.length ||
				columns.some(
					(c) =>
						!text(c.name) ||
						!integer(c.cid) ||
						!integer(c.pk) ||
						!integer(c.hidden) ||
						![0, 1, 2, 3].includes(c.hidden) ||
						typeof c.type !== 'string' ||
						!integer(c.notnull) ||
						(c.dflt_value !== null && typeof c.dflt_value !== 'string')
				)
			)
				throw fail();
			columns.sort((a, b) => (a.cid as number) - (b.cid as number));
			const definition = schema.find((r) => r.name === name && r.type === 'table')!;
			if (table.type === 'virtual' && !/\bUSING\s+fts5\s*\(/i.test(String(definition.sql)))
				throw new Error('Unsupported virtual table inventory.');
			// FTS5 hidden table/rank columns are query handles/derived ranks, not stored
			// values. Keep their schema; capture every visible value AND all shadow bytes.
			if (table.type !== 'virtual' && columns.some((c) => c.hidden === 1)) throw fail();
			const values = columns.filter((c) => c.hidden !== 1);
			if (!values.length) throw fail();
			add('database-schema', JSON.stringify(['columns', name]), [
				table.type,
				table.wr,
				table.strict,
				columns.map((c) => [c.cid, c.name, c.type, c.notnull, c.dflt_value, c.pk, c.hidden])
			]);
			const rowid =
				table.wr === 0
					? ['rowid', '_rowid_', 'oid'].find(
							(alias) => !columns.some((c) => fold(c.name as string) === alias)
						)
					: undefined;
			if (table.wr === 0 && !rowid)
				throw new Error('Hidden rowid cannot be inventoried through SQL.');
			const primary = values
				.map((c, i) => ({ index: i, order: c.pk as number, name: c.name as string }))
				.filter((c) => c.order > 0)
				.sort((a, b) => a.order - b.order);
			if (!rowid && !primary.length) throw fail();
			const order = rowid ? q(rowid) : primary.map((c) => q(c.name)).join(',');
			for (let offset = 0; ;) {
				let rows: Cell[][] | undefined;
				let ids: string[] = [];
				let pageBytes = 0;
				for (let start = 0; start < values.length; start += 8) {
					const chunk = values.slice(start, start + 8);
					const projection = chunk.flatMap((c, i) => {
						const column = q(c.name as string);
						return [
							`typeof(${column}) AS t${i}`,
							`CASE typeof(${column}) WHEN 'integer' THEN CAST(${column} AS TEXT) WHEN 'real' THEN ${column} WHEN 'text' THEN CASE WHEN length(CAST(${column} AS BLOB))<=1048576 THEN hex(CAST(${column} AS BLOB)) ELSE 'OVERSIZE' END WHEN 'blob' THEN CASE WHEN length(${column})<=1048576 THEN hex(${column}) ELSE 'OVERSIZE' END ELSE NULL END AS v${i}`
						];
					});
					const page = await driver.all(
						`SELECT ${rowid ? `CAST(${q(rowid)} AS TEXT) AS _rid,` : ''}${projection.join(',')} FROM main.${q(name)} ORDER BY ${order} LIMIT 4 OFFSET ${offset}`
					);
					if (page.length > 4) throw fail();
					if (rows === undefined) {
						rows = page.map(() => []);
						ids = page.map((r) => (rowid ? (cell('integer', r._rid)[1] as string) : ''));
					}
					if (page.length !== rows.length) throw fail();
					for (let i = 0; i < page.length; i++) {
						if (rowid && cell('integer', page[i]._rid)[1] !== ids[i]) throw fail();
						if (Object.keys(page[i]).length !== chunk.length * 2 + (rowid ? 1 : 0)) throw fail();
						const converted = chunk.map((_, j) => cell(page[i][`t${j}`], page[i][`v${j}`]));
						pageBytes += encoder.encode(JSON.stringify(converted)).length;
						if (budget + pageBytes > limit)
							throw new Error('SQLite inventory requires a streaming host for this workspace.');
						rows[i].push(...converted);
					}
					if (!page.length) break;
				}
				if (!rows) throw fail();
				for (let i = 0; i < rows.length; i++) {
					const key = JSON.stringify(
						rowid ? [name, 'rowid', ids[i]] : [name, 'pk', primary.map((c) => rows![i][c.index])]
					);
					add('database-values', key, rows[i]);
					if (pendingTables.includes(name)) add('pending-intents', key, rows[i]);
				}
				if (rows.length < 4) break;
				offset += rows.length;
			}
		}
		return out;
	});
}
