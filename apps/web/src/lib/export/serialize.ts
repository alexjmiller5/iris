import type { Property, Row } from 'iris-core/client';

export interface ExportSnapshot {
	table: string;
	properties: readonly Readonly<Property>[];
	rows: readonly Readonly<Row>[];
	scope: 'loaded' | 'view' | 'table';
	completeness: {
		/** Complete applies only to the supplied/selected ID set, never remote coverage. */
		rows: 'complete' | 'partial' | 'unknown';
		columns: 'full' | 'projected';
		reasons: readonly string[];
	};
	acquisition: {
		source: 'local-replica' | 'online-page';
		capturedAt: string;
		freshness: 'unknown';
		/** Last observed status, acquired separately from the rows. */
		lastSync: string | null;
		skippedTables: readonly string[];
		pendingUiEdits: number | null;
		rejectedEdits: number | null;
	};
}
export interface ExportOptions {
	format: 'json' | 'csv';
	selectedIds?: readonly string[];
}
export interface ExportFile {
	filename: string;
	mimeType: string;
	text: string;
}
export interface ExportArtifact {
	files: ExportFile[];
	rowCount: number;
}

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

// Reject values JSON would silently change. Sorting object keys never changes array/row order.
function canonical(value: unknown, parents = new Set<object>()): JSONValue {
	if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
	if (typeof value === 'number') {
		if (
			!Number.isFinite(value) ||
			Object.is(value, -0) ||
			(Number.isInteger(value) && !Number.isSafeInteger(value))
		)
			throw new Error('A number cannot be exported to JSON without loss.');
		return value;
	}
	if (typeof value !== 'object' || parents.has(value))
		throw new Error('Unsupported or cyclic JSON value.');
	parents.add(value);
	try {
		if (Array.isArray(value)) return Array.from(value, (item) => canonical(item, parents));
		if (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)
			throw new Error('Unsupported JSON value.');
		return Object.fromEntries(
			Object.keys(value)
				.sort()
				.map((key) => [key, canonical((value as Row)[key], parents)])
		);
	} finally {
		parents.delete(value);
	}
}
const json = (value: unknown) => JSON.stringify(canonical(value), null, 2) + '\n';
const quote = (text: string) =>
	`"${(/^[\s\u0000-\u001f]*[=+@-]/u.test(text) ? "'" : '') + text.replaceAll('"', '""')}"`;
const csvCell = (value: unknown): string => {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return quote(value);
	if (typeof value === 'object') return quote(JSON.stringify(canonical(value)));
	return String(value);
};

/** Pure serialization of caller-acquired immutable rows. No acquisition, sync or restore. */
export function serializeExport(snapshot: ExportSnapshot, options: ExportOptions): ExportArtifact {
	const { table, properties, completeness, acquisition } = snapshot;
	if (
		!completeness ||
		!['complete', 'partial', 'unknown'].includes(completeness.rows) ||
		!['full', 'projected'].includes(completeness.columns) ||
		!Array.isArray(completeness.reasons)
	)
		throw new Error('Explicit completeness metadata is required.');
	if (
		!['loaded', 'view', 'table'].includes(snapshot.scope) ||
		(snapshot.scope !== 'loaded' && completeness.rows === 'complete')
	)
		throw new Error('A view or table export cannot claim complete coverage.');
	if (
		!acquisition ||
		!['local-replica', 'online-page'].includes(acquisition.source) ||
		!Number.isFinite(Date.parse(acquisition.capturedAt)) ||
		acquisition.freshness !== 'unknown'
	)
		throw new Error('Explicit acquisition source, capture time and freshness are required.');
	if (!table || properties.some((p) => p.tbl !== table || !p.col))
		throw new Error('Export catalog metadata must belong to the captured table.');
	// Validate before filtering so a malformed capture cannot conceal ambiguous identities.
	const ids = new Set<string>();
	for (const row of snapshot.rows) {
		if (typeof row.id !== 'string' || !row.id || ids.has(row.id))
			throw new Error('Every captured row must have a unique string identity.');
		ids.add(row.id);
	}
	let rows = snapshot.rows;
	if (options.selectedIds !== undefined) {
		const selection = new Set(options.selectedIds);
		if (selection.size !== options.selectedIds.length || [...selection].some((id) => !ids.has(id)))
			throw new Error('The selection has duplicate or missing row IDs. Reload and select again.');
		rows = rows.filter((row) => selection.has(row.id as string));
	}
	canonical(rows);
	const scope = {
		kind: options.selectedIds === undefined ? snapshot.scope : 'selection',
		rowCount: rows.length
	};
	const metadata = {
		format: 'iris-records',
		version: 1,
		table,
		properties,
		scope,
		completeness,
		acquisition
	};
	const name = table.replace(/[^a-zA-Z0-9_-]+/g, '-').slice(0, 80) || 'records';
	const basename = `${name}-${scope.kind}-${completeness.rows}-${completeness.columns}`;
	if (options.format === 'json')
		return {
			rowCount: rows.length,
			files: [
				{
					filename: `${basename}.json`,
					mimeType: 'application/json;charset=utf-8',
					text: json({ ...metadata, rows })
				}
			]
		};
	if (options.format !== 'csv') throw new Error('Unsupported export format.');
	const columns = [...new Set(['id', ...properties.map((p) => p.col)])];
	columns.push(
		...[...new Set(rows.flatMap((row) => Object.keys(row)))]
			.filter((key) => !columns.includes(key))
			.sort()
	);
	return {
		rowCount: rows.length,
		files: [
			{
				filename: `${basename}.csv`,
				mimeType: 'text/csv;charset=utf-8',
				text:
					[
						columns.map(quote).join(','),
						...rows.map((row) =>
							columns.map((key) => csvCell(Object.hasOwn(row, key) ? row[key] : null)).join(',')
						)
					].join('\r\n') + '\r\n'
			},
			{
				filename: `${basename}.metadata.json`,
				mimeType: 'application/json;charset=utf-8',
				text: json({
					...metadata,
					csv: {
						columns,
						lossless: false,
						formulaProtection: 'apostrophe-prefix',
						nullAndMissing: 'unquoted-empty',
						emptyString: 'quoted-empty'
					}
				})
			}
		]
	};
}
