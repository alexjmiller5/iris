import { expect, test } from 'vitest';
import { serializeExport, type ExportSnapshot } from './serialize';

const snapshot: ExportSnapshot = {
	table: 'entries',
	properties: [
		{ tbl: 'entries', col: 'body', type: 'markdown', label: 'Content' },
		{ tbl: 'entries', col: 'empty', type: 'text' }
	],
	rows: [
		{ id: 'e\u0301', body: '# Raw\r\n\r\n<tag> _text_  \n', empty: '', nullable: null },
		{ id: '\u00e9', body: '雪 🦉', empty: null, nested: { z: 0, a: [false, ''] } }
	],
	scope: 'loaded',
	acquisition: {
		source: 'local-replica',
		capturedAt: '2026-01-01T00:00:00.000Z',
		freshness: 'unknown',
		lastSync: null,
		skippedTables: [],
		pendingUiEdits: null,
		rejectedEdits: null
	},
	completeness: { rows: 'partial', columns: 'full', reasons: ['More rows are available.'] }
};

// Catches Unicode normalization, Markdown reformatting, and dropping empty/null values.
test('JSON preserves exact record values and catalog properties with partial-capture metadata', () => {
	const result = serializeExport(snapshot, { format: 'json' });
	expect(result.files).toHaveLength(1);
	const exported = JSON.parse(result.files[0].text);
	expect(exported.rows).toEqual([
		{ id: 'e\u0301', body: '# Raw\r\n\r\n<tag> _text_  \n', empty: '', nullable: null },
		{ id: '\u00e9', body: '雪 🦉', empty: null, nested: { z: 0, a: [false, ''] } }
	]);
	expect(exported.properties).toEqual([
		{ tbl: 'entries', col: 'body', type: 'markdown', label: 'Content' },
		{ tbl: 'entries', col: 'empty', type: 'text' }
	]);
	expect(exported.completeness).toEqual({
		rows: 'partial',
		columns: 'full',
		reasons: ['More rows are available.']
	});
	expect(exported.scope).toEqual({ kind: 'loaded', rowCount: 2 });
	expect(exported.format).toBe('life-ui-records');
	expect(exported.version).toBe(1);
	expect(result.files[0].filename).toContain('partial');
});

// Catches sorting or rebuilding a snapshot in place, and insertion-order-dependent output.
test('serialization is deterministic without mutating frozen inputs', () => {
	const rows = Object.freeze([Object.freeze({ id: 'one', b: 2, a: 1 })]);
	const input = Object.freeze({ ...snapshot, rows });
	const a = serializeExport(input, { format: 'json' });
	const b = serializeExport({ ...snapshot, rows: [{ a: 1, b: 2, id: 'one' }] }, { format: 'json' });
	expect(a).toEqual(b);
	expect(rows[0]).toEqual({ id: 'one', b: 2, a: 1 });
});

// Catches accidentally exporting all loaded rows or normalizing opaque selection IDs.
test('selection exports only byte-exact selected IDs in captured row order', () => {
	const result = serializeExport(snapshot, { format: 'json', selectedIds: ['\u00e9'] });
	const exported = JSON.parse(result.files[0].text);
	expect(exported.rows).toEqual([
		{ id: '\u00e9', body: '雪 🦉', empty: null, nested: { z: 0, a: [false, ''] } }
	]);
	expect(exported.scope).toEqual({ kind: 'selection', rowCount: 1 });
	expect(exported.completeness.rows).toBe('partial');
	expect(() => serializeExport(snapshot, { format: 'json', selectedIds: ['missing'] })).toThrow(
		/selection/i
	);
	expect(() =>
		serializeExport(snapshot, { format: 'json', selectedIds: ['\u00e9', '\u00e9'] })
	).toThrow(/selection/i);
});

test('an empty explicit selection never falls back to all rows', () => {
	const result = serializeExport(snapshot, { format: 'json', selectedIds: [] });
	expect(JSON.parse(result.files[0].text).rows).toEqual([]);
	expect(result.rowCount).toBe(0);
});

// Catches JSON.stringify silently converting unsupported acquired values into different data.
test.each([NaN, Infinity, -0, 9007199254740992, undefined, 1n, new Uint8Array([1]), new Date(0)])(
	'refuses a value that JSON cannot preserve exactly: %s',
	(value) => {
		expect(() =>
			serializeExport({ ...snapshot, rows: [{ id: 'one', value }] }, { format: 'json' })
		).toThrow(/JSON|value|number/i);
	}
);

test('refuses missing or duplicate row identities without guessing', () => {
	for (const rows of [[{ id: 7 }], [{ body: 'No id' }], [{ id: 'one' }, { id: 'one' }]]) {
		expect(() => serializeExport({ ...snapshot, rows }, { format: 'json' })).toThrow(/identit/i);
	}
});

test('refuses absent completeness metadata instead of claiming a complete table', () => {
	expect(() =>
		serializeExport({ ...snapshot, completeness: undefined } as unknown as ExportSnapshot, {
			format: 'json'
		})
	).toThrow(/completeness/i);
	const result = serializeExport(
		{
			...snapshot,
			scope: 'table',
			completeness: {
				rows: 'unknown',
				columns: 'projected',
				reasons: []
			}
		},
		{ format: 'json' }
	);
	expect(result.files[0].filename).toContain('unknown');
	expect(JSON.parse(result.files[0].text).completeness.columns).toBe('projected');
});

// Catches row-column dropping, spreadsheet formulas, and null/empty collapse in the raw CSV.
test('CSV uses exact column keys, escaped text, formula protection and a completeness sidecar', () => {
	const result = serializeExport(
		{
			...snapshot,
			rows: [
				{ id: '001', body: 'line,"one"\r\n雪', empty: '', nullable: null, extra: '\t=2+2' },
				{
					id: '002',
					body: '=HYPERLINK("https://example.invalid")',
					empty: null,
					nullable: false,
					extra: 0
				}
			]
		},
		{ format: 'csv' }
	);
	expect(result.files).toHaveLength(2);
	expect(result.files[0].text).toBe(
		'"id","body","empty","extra","nullable"\r\n' +
			'"001","line,""one""\r\n雪","","\'\t=2+2",\r\n' +
			'"002","\'=HYPERLINK(""https://example.invalid"")",,0,false\r\n'
	);
	const metadata = JSON.parse(result.files[1].text);
	expect(metadata.completeness.rows).toBe('partial');
	expect(metadata.csv.columns).toEqual(['id', 'body', 'empty', 'extra', 'nullable']);
	expect(metadata.csv.lossless).toBe(false);
	expect(metadata).not.toHaveProperty('rows');
	expect(result.files.every((file) => file.filename.includes('partial'))).toBe(true);
});

test('CSV protects dangerous column names and retains object fields as JSON text', () => {
	const result = serializeExport(
		{
			...snapshot,
			properties: [],
			rows: [{ id: 'one', '=column': { z: false, a: null }, ' spaced': '  +42' }]
		},
		{ format: 'csv' }
	);
	expect(result.files[0].text).toBe(
		'"id"," spaced","\'=column"\r\n"one","\'  +42","{""a"":null,""z"":false}"\r\n'
	);
});

test('empty CSV retains catalog columns and exports a metadata sidecar', () => {
	const result = serializeExport({ ...snapshot, rows: [] }, { format: 'csv' });
	expect(result.files[0].text).toBe('"id","body","empty"\r\n');
	expect(JSON.parse(result.files[1].text).scope.rowCount).toBe(0);
});

test('rejects mismatched property metadata and keeps hostile names out of filenames', () => {
	expect(() =>
		serializeExport(
			{ ...snapshot, properties: [{ tbl: 'other', col: 'body', type: 'markdown' }] },
			{ format: 'json' }
		)
	).toThrow(/catalog/i);
	const result = serializeExport(
		{ ...snapshot, table: '../x\u0000/y', properties: [] },
		{ format: 'json' }
	);
	expect(result.files[0].filename).not.toMatch(/[\/\\\u0000]/);
	expect(JSON.parse(result.files[0].text).table).toBe('../x\u0000/y');
});

test('never certifies a whole view or table from supplied rows', () => {
	for (const scope of ['view', 'table'] as const) {
		expect(() =>
			serializeExport(
				{
					...snapshot,
					scope,
					completeness: {
						...snapshot.completeness,
						rows: 'complete'
					}
				},
				{ format: 'json' }
			)
		).toThrow(/complete/i);
	}
	const result = serializeExport(
		{
			...snapshot,
			completeness: {
				...snapshot.completeness,
				rows: 'complete'
			}
		},
		{ format: 'json', selectedIds: ['é'] }
	);
	expect(JSON.parse(result.files[0].text).scope).toEqual({ kind: 'selection', rowCount: 1 });
});

test('preserves acquisition caveats and rejects a missing capture source', () => {
	const result = serializeExport(snapshot, { format: 'json' });
	expect(JSON.parse(result.files[0].text).acquisition).toEqual(snapshot.acquisition);
	expect(() =>
		serializeExport({ ...snapshot, acquisition: undefined } as unknown as ExportSnapshot, {
			format: 'json'
		})
	).toThrow(/acquisition/i);
});

test('rejects cyclic and sparse values rather than replacing them with null', () => {
	const cycle: Record<string, unknown> = {};
	cycle.self = cycle;
	for (const value of [cycle, Array(2)]) {
		expect(() =>
			serializeExport({ ...snapshot, rows: [{ id: 'one', value }] }, { format: 'json' })
		).toThrow(/JSON/i);
	}
});

test('projected CSV never exports inherited object members as missing cell data', () => {
	const result = serializeExport(
		{
			...snapshot,
			rows: [{ id: 'one' }],
			properties: [{ tbl: 'entries', col: 'toString', type: 'text' }],
			completeness: { ...snapshot.completeness, columns: 'projected' }
		},
		{ format: 'csv' }
	);
	expect(result.files[0].text).toBe('"id","toString"\r\n"one",\r\n');
	expect(JSON.parse(result.files[1].text).completeness.columns).toBe('projected');
});
