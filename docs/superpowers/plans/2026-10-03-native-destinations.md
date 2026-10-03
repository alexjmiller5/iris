# Native destination and palette models

Implement the approved native navigation parity model slice. URL transport,
intake, production views and editor integration remain separate work. Use the
existing generated catalog, saved-view and row operations; add no SQL or wire DTO.
The existing native navigation task names `life://` links. Future intake/copy
must bind to the intended deployment or local workspace; this model receives
its workspace from the caller and does not define that external link envelope.

## Shared destination seam

Create `packages/LifeKit/Sources/LifeKit/NativeDestination.swift`:

- `NativeDestination(table:viewID:rowID:)` is Codable, Hashable and Sendable.
  Optional IDs default to nil; Codable keys are `table`, `view`, `row`. Request
  Strings stay unchanged; equality/hash use the exact UTF-8 tuple, including nil.
- `NativeResolvedDestination` carries `destination`, fresh `catalog`, optional
  generated `view`, optional full `row`, and derived `label`/`isTrashed`.
- `NativeDestinationResolver(workspace:)` offers
  `resolve(_:isCurrent:) async throws -> NativeResolvedDestination`. The caller
  owns generation; concurrent consumers do not cancel one another. Check task
  cancellation and context before/after every core read, including failed reads.
- Resolve catalog membership, then current saved-view availability and table
  ownership, then a full exact-ID row using active/trash queries. Missing and
  unavailable destinations throw `WorkspaceError`; stale work throws
  `CancellationError`. Do not mutate a workspace, draft, history or preference.
- Native recents consumes this seam, without another resolver.

Core owns SQL identifier validation and record querying. Supported table names
are ASCII identifiers. A generated ID-filter query can match an alias through
the primary key's affinity/collation, so the resolver also verifies that the
returned full row has the exact requested ID bytes. Host destination identities
and saved-view array selection use UTF-8 bytes, without normalizing request Strings.

## Palette metadata seam

Create `packages/LifeKit/Sources/LifeKit/NativePaletteModel.swift`:

- Discover catalog tables and progressively append generated saved views once
  per opening, with explicit retry/refresh. Read metadata only, not record rows.
- Expose table/view entries, loading and partial errors; unavailable views remain
  visible with a reason. Filter labels/table names locally using web semantics.
- Entry identity includes kind, table and exact view-ID bytes. Preserve record
  FTS and its paging in the existing QuickFindModel, which this slice never edits.
- Refresh supersedes old replies; disposal is permanent; caller workspace
  guards and task cancellation stop further reads and obsolete publications.

## TDD and verification

- [x] Establish the baseline in the dedicated SwiftPM scratch/cache root.
- [x] Add failing `NativeDestinationTests.swift`: Codable/opaque-ID round trips,
  actual JSC/GRDB table/view/full active and tombstoned rows, renamed/deleted and
  unavailable views, missing destinations, and byte-distinct record/view IDs.
- [x] Add controlled async stale success/error tests at each read boundary,
  including caller cancellation and independent concurrent resolutions.
- [x] Implement the smallest resolver satisfying those tests; hand its API to
  the recents consumer after focused GREEN.
- [x] Add failing `NativePaletteTests.swift`: progressive partial metadata,
  independent failures, no per-keystroke reads, exact identity, explicit retries,
  superseded replies, disposal and workspace/cancellation guards. Implement GREEN.
- [x] Run behavior mutants, restore sources, then run all LifeKit SwiftPM tests.
  Review the diff before publication. Commit/push and CI are tracked in the handoff.

Verification: 17 new test functions cover the resolver and palette. Resolver and
palette behavior first failed before implementation; a real JSC NOCASE fixture
also failed for both live and trashed row aliases before the exact-ID guard.
All 26 semantic mutants were caught. The restored full SwiftPM run reports 186
tests in 35 suites with five existing live-fixture tests skipped. Bounded source
review is clear after the NOCASE correction.

Only isolated SwiftPM execution is leased. Use unique scratch/cache/config/module
directories outside the checkout. No Xcode, simulator, CDP, resource generation,
main checkout changes, QuickFindModel changes or identity/recovery refactoring.

## Later UI integration

Create one palette model per opening and call `load()`. Bind text to `query`;
`filteredEntries` searches metadata locally while the existing QuickFindModel
retains record FTS and paging. Render entries with their byte-exact `id`, display
`error` alongside partial results, and offer `refresh()` for an explicit retry.
Disable entries with `unavailable`; dispose the model on close. Selection and
keyboard handling belong to the later UI slice.

On activation, resolve the selected `destination` using a caller generation and
the explicitly open workspace. Resolution does not apply a table/view, open an
editor, clear a draft or record a recent. The existing guarded navigation path
must approve draft loss and install the fresh result before recording success.
Pass an owner-context closure to the palette and resolver, so switching workspace
or closing the palette invalidates replies without sharing generation counters
between independent callers.
