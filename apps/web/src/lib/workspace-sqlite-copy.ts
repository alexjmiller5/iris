import { collectSQLiteInventory, type SQLiteInventoryDriver } from './workspace-sqlite-inventory';

type Column = { name: string; hidden: number };
type Table = { name: string; type: string; withoutRowid: boolean; columns: Column[] };
export type SQLiteLogicalCopyPlan = {
	metadata: { user_version: number; application_id: number; encoding: string; auto_vacuum: number };
	creates: string[];
	copies: {
		name: string;
		columns: string[];
		rowid: string | null;
		clear: boolean;
		kind: 'table' | 'shadow' | 'sequence' | 'statistics';
	}[];
	deferred: string[];
	initializeStatistics: boolean;
	/** Target must permit native shadow writes already; never disable defensive mode. */
	requiresShadowWrites: boolean;
	snapshot: Awaited<ReturnType<typeof collectSQLiteInventory>>;
};
const fail = () => new Error('This SQLite schema requires a supported lossless copy strategy.');
const fold = (name: string) => name.replace(/[A-Z]/g, (c) => c.toLowerCase());
function identifier(input: string): { name: string; rest: string } {
	const match = input
		.trimStart()
		.match(/^(?:"((?:[^"]|"")*)"|`((?:[^`]|``)*)`|\[([^\]]*)\]|([A-Za-z_][A-Za-z0-9_$]*))/);
	if (!match) throw fail();
	const name =
		match[1]?.replaceAll('""', '"') ?? match[2]?.replaceAll('``', '`') ?? match[3] ?? match[4];
	if (!name) throw fail();
	return { name, rest: input.trimStart().slice(match[0].length) };
}
function defaultFTS(sql: string, table: Table) {
	const prefix = /^\s*CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?/i.exec(sql);
	if (!prefix) throw fail();
	const named = identifier(sql.slice(prefix[0].length));
	const body = /^\s+USING\s+fts5\s*\(([\s\S]*)\)\s*$/i.exec(named.rest);
	if (named.name !== table.name || !body) throw fail();
	const names: string[] = [];
	// Canonical core explicitly names the default tokenizer; all other options refuse.
	let rest = body[1].replace(/,\s*tokenize\s*=\s*'unicode61'\s*$/i, '');
	for (;;) {
		const column = identifier(rest);
		names.push(column.name);
		rest = column.rest.trim();
		if (!rest) break;
		if (!rest.startsWith(',')) throw fail();
		rest = rest.slice(1);
	}
	const visible = table.columns
		.filter((column) => column.hidden === 0)
		.map((column) => column.name);
	if (JSON.stringify(names) !== JSON.stringify(visible)) throw fail();
	return names;
}
/** Read-only planning over one stable source snapshot. No execution, target
 * admission, publication or cleanup authority. Unknown schemas retain the source.
 * Values remain in SQLite during the future INSERT SELECT transfer; this plan's
 * canonical inventory is preservation evidence, never a dump or import stream.
 */
export async function planSQLiteLogicalCopy(
	driver: SQLiteInventoryDriver
): Promise<SQLiteLogicalCopyPlan> {
	return driver.transaction(async () => {
		const snapshot = await collectSQLiteInventory({
			...driver,
			transaction: async (work) => work()
		});
		const definitions: { type: string; name: string; sql: string | null }[] = [];
		const tables = new Map<string, Table>();
		const metadata: Record<string, number | string> = {};
		for (const row of snapshot['database-schema']) {
			const key = JSON.parse(row.key),
				value = JSON.parse(new TextDecoder().decode(row.value));
			if (key[0] === 'metadata') metadata[key[1]] = value;
			else if (key[0] === 'ddl')
				definitions.push({ type: value[0], name: value[1], sql: value[3] });
			else if (key[0] === 'columns')
				tables.set(key[1], {
					name: key[1],
					type: value[0],
					withoutRowid: value[1] === 1,
					columns: value[3].map((column: unknown[]) => ({
						name: column[1] as string,
						hidden: column[6] as number
					}))
				});
			else throw fail();
		}
		const tableDefinitions = new Map(
			definitions.filter((entry) => entry.type === 'table').map((entry) => [entry.name, entry])
		);
		const shadows = new Set<string>();
		for (const table of tables.values()) {
			if (table.type !== 'virtual') continue;
			const ddl = tableDefinitions.get(table.name);
			if (!ddl?.sql) throw fail();
			const columns = defaultFTS(ddl.sql, table);
			const expected = {
				data: ['id', 'block'],
				idx: ['segid', 'term', 'pgno'],
				content: ['id', ...columns.map((_, i) => `c${i}`)],
				docsize: ['id', 'sz'],
				config: ['k', 'v']
			};
			for (const [suffix, names] of Object.entries(expected)) {
				const name = table.name + '_' + suffix,
					shadow = tables.get(name);
				if (
					!shadow ||
					shadow.type !== 'shadow' ||
					shadows.has(name) ||
					JSON.stringify(shadow.columns.map((column) => column.name)) !== JSON.stringify(names)
				)
					throw fail();
				shadows.add(name);
			}
		}
		const creates: string[] = [],
			deferred: string[] = [];
		const copies: SQLiteLogicalCopyPlan['copies'] = [];
		let initializeStatistics = false;
		for (const table of tables.values()) {
			const ddl = tableDefinitions.get(table.name);
			if (!ddl?.sql) throw fail();
			if (table.type === 'shadow' && !shadows.has(table.name)) throw fail();
			let kind: SQLiteLogicalCopyPlan['copies'][number]['kind'] = shadows.has(table.name)
				? 'shadow'
				: 'table';
			if (table.name.startsWith('sqlite_')) {
				if (table.name === 'sqlite_sequence') kind = 'sequence';
				else if (table.name === 'sqlite_stat1' || table.name === 'sqlite_stat4') {
					kind = 'statistics';
					initializeStatistics = true;
					const expected =
						table.name === 'sqlite_stat1'
							? ['tbl', 'idx', 'stat']
							: ['tbl', 'idx', 'neq', 'nlt', 'ndlt', 'sample'];
					if (
						JSON.stringify(table.columns.map((column) => column.name)) !== JSON.stringify(expected)
					)
						throw fail();
				} else throw fail();
			}
			if (kind === 'table') creates.push(ddl.sql);
			if (table.type === 'virtual') continue;
			const rowid = table.withoutRowid
				? null
				: ['rowid', '_rowid_', 'oid'].find(
						(alias) => !table.columns.some((column) => fold(column.name) === alias)
					);
			if (rowid === undefined) throw fail();
			copies.push({
				name: table.name,
				columns: table.columns.filter((column) => column.hidden === 0).map((column) => column.name),
				rowid,
				clear: kind !== 'table',
				kind
			});
		}
		for (const entry of definitions) {
			if (entry.type === 'table' || entry.sql === null) continue;
			if (!['index', 'view', 'trigger'].includes(entry.type)) throw fail();
			deferred.push(entry.sql);
		}
		// Inserts update sequence state; restore its exact original values after every table.
		const rank = { table: 0, shadow: 0, sequence: 1, statistics: 2 };
		copies.sort((a, b) => rank[a.kind] - rank[b.kind]);
		return {
			metadata: metadata as SQLiteLogicalCopyPlan['metadata'],
			creates,
			copies,
			deferred,
			initializeStatistics,
			requiresShadowWrites: shadows.size > 0,
			snapshot
		};
	});
}
