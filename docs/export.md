# Record export

The records toolbar exports currently loaded, persisted local rows. It does not
save drafts, sync, fetch additional pages, include file bytes, or create a
backup. The control shows the loaded count and unknown table completeness and
freshness, and disables export during row/context loading.

Choose JSON for exact supported values. CSV can lose types when a spreadsheet
opens it. After downloading CSV, use **Download CSV metadata** for its companion
JSON. That button retains metadata for the last CSV capture after the page
changes. Each download has its own action; no multiple-download permission is
needed.

## Host contract

`ExportPanel.svelte` accepts `snapshot: ExportSnapshot | null`, `disabled`, and
optional `selectedIds`. The host supplies a detached copy of committed rows and
catalog properties from the current dataset/table/view generation, invalidating
it before row or context requests. The component synchronously serializes all
files before the first download. Neither module acquires records or writes data.

`serializeExport(snapshot, { format: 'json' | 'csv', selectedIds? })` returns
`{ rowCount, files: [{ filename, mimeType, text }] }`. CSV returns two files:
CSV, then metadata. JSON returns one. Missing or duplicate selected IDs fail
visibly. Empty selection exports zero rows. IDs are exact, unnormalized strings.

The snapshot supplies:

- `table`, catalog `properties`, and `rows`, in supplied order.
- `scope`: `loaded`, `view`, or `table`. The workspace always uses `loaded`,
  including saved views. Selection outputs `selection` and its exact row count.
- `completeness`: rows `complete`, `partial`, or `unknown`; columns `full` or
  `projected`; explanatory `reasons`. Complete means only the explicit supplied
  or selected ID set. View/table captures cannot claim complete coverage. The
  current host uses unknown row coverage. Its unprojected query supplies full
  columns regardless of grid visibility; projections must stay projected.
- `acquisition`: `source` (`local-replica` or `online-page`), ISO `capturedAt`,
  `freshness: 'unknown'`, and last-observed `lastSync`, `skippedTables`,
  `pendingUiEdits`, `rejectedEdits`. Unknown counts/time use null. Status and
  catalog are acquired separately from rows. Skipped tables describe last pull
  history; an empty list and successful sync certify neither coverage nor
  freshness. The first adapter is local only.

A future complete-table acquisition belongs to Soma and must hold catalog,
rows and bounded full enumeration under one local read snapshot. Exhausting
pagination on a changing hub cannot certify it. This module has no SQL, hub,
restore or backup API.

## Files

Version 1 JSON includes `format: 'iris-records'`, `version: 1`, `table`,
`properties`, `rows`, `scope: { kind, rowCount }`, `completeness`, and
`acquisition`. Object keys are sorted; arrays retain supplied order. Filenames
use a safe table stem, scope and completeness. Capture time comes from the
caller; identical inputs produce identical bytes.

JSON preserves strings (Unicode and raw Markdown included), null, booleans,
finite numbers, arrays and plain objects. Unsupported values fail rather than
silently change: undefined, bigint, unsafe integers, negative zero, non-finite
numbers, binary/class instances, cycles and sparse arrays. Lossless means
supported acquired JSON values; precision already lost crossing the
JavaScript/SQLite boundary cannot be recovered. Absent fields stay absent;
null and empty strings remain distinct. Retained file references remain
references; file bytes are not acquired or bundled.

CSV columns are `id`, catalog keys in supplied order, then other acquired keys
sorted. CRLF separates rows; embedded quotes/newlines/commas are escaped. Null
and missing values are unquoted empty cells; empty strings are quoted. Nested
values become JSON text. Formula-like text and column names receive an
apostrophe prefix, including markers after whitespace/control characters.
Spreadsheets may still coerce IDs, dates, numbers and empty cells. CSV is not
lossless or a restore format. Its sidecar retains catalog, acquisition,
completeness, exact column keys and escaping policy without row contents.

## Verification

Pure fixtures: `bun run --cwd apps/web test -- src/lib/export/serialize.spec.ts`.
The browser test covers the mounted toolbar, download events, metadata, exact
stored Markdown, unsaved drafts, loading, table switches, and a CSV sidecar
retained across navigation:

```sh
bun run --cwd apps/web dev --port 5256 --strictPort
# Open an owned tab at http://iris-export.localhost:5256/workspace?review
bun scripts/test-export.ts
```

Use the existing agent browser at CDP port 9222. The script guards its exact
disposable origin, seeds the separate sample workspace through supported APIs,
and clears only that origin afterwards. It changes no browser-wide download
preferences and never resets an enrolled workspace.
