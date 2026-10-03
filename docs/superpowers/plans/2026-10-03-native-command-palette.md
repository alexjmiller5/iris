# Native command palette integration

Integrate table and saved-view destinations with the existing native record
search. Start from the combined main containing the verified destination,
recents and saved-view identity models. This slice owns QuickFindView, bounded
QuickFindModel changes, a coordinator, the workspace palette factory/activation
helper and the Quick Find sheet handlers. Sidebar, grid, RecordEditor, resources
and external URL intake are separate work.

## Model and UI seams

- A `QuickFindCoordinator` combines `NativePaletteModel` metadata with existing
  `QuickFindModel` FTS results and paging. Entries use `NativeDestination` as
  their exact kind/table/ID identity. Labels and array positions are not keys.
- The coordinator owns selection and activation. Reconcile selection when
  enabled entry identities change, retaining the selected identity if present.
  Up/Down wrap through enabled entries; Enter activates the selected entry.
  Metadata arrivals and appended record pages must not move a retained selection.
- Typing filters metadata locally and uses the current 200 ms record-search
  debounce. Empty queries still show tables/views. Keep unavailable views and
  their reasons visible, show partial metadata failures, and support explicit
  metadata retry independently of record paging/retry.
- Every activation uses `NativeDestinationResolver` and caller generation.
  Query change, replacement activation, workspace change and closure invalidate
  late successes and errors. Never open a cached search result's record values.
- A synchronous workspace activation helper checks the original workspace and
  generation before changing state. Apply fresh catalog/view metadata and reset
  stale view settings even when navigating to the same table. Retain full fresh
  row values and explicit trash state for editor presentation.
- Preserve the existing guard that prevents opening the palette while a record
  sheet is open. A row still uses the existing pending-editor sheet handoff.
  Carry its destination through that handoff and call the shared host hook
  `recordNavigationSucceeded(_:)` only after the editor is actually installed.
  Table/view activation calls the same hook after installation, never on lookup.

## TDD sequence

1. Establish the merged baseline using isolated SwiftPM caches when the parent
   releases the compile slot. Add failing coordinator tests before production.
2. Cover mixed entry identities (including composed/decomposed row and view IDs),
   async selection retention, keyboard wrapping/skipping disabled entries, query
   changes, raw-offset record pagination and independent metadata errors/retry.
3. Use controlled continuations for stale success/error on close, workspace
   change, query change and replacement activation; no stale navigation or errors.
4. Use actual GRDB/JSC for renamed/deleted views, fresh full rows, same-table
   default-view reset, trash destinations and stale workspace activation. Retain
   existing record search and byte-exact identity regression coverage.
5. Implement coordinator/helper GREEN, then wire the permitted SwiftUI sections.
   Use the same action methods for keyboard and pointer activation. Render each
   list entry with its exact identity and preserve selection while results arrive.
6. Run meaningful semantic mutants and the full SwiftPM suite after restoring
   sources. Request native UI verification from the sole Xcode/simulator owner
   when compilation is ready; the parent reviews the integrated source.

## Native UI verification handoff

Verify Cmd+K and the existing Find buttons, blank-query tables/views, Up/Down and
Enter selection, disabled view reasons, narrow iOS layout, metadata arriving
after record results, record paging, close/reopen with late replies, renamed and
deleted destinations, and the record-sheet exclusion guard. Opening a result
must show fresh contents. Successful navigation is recorded once after commit;
failed or canceled activation leaves the palette and prior workspace unchanged.

Only isolated SwiftPM execution is leased to this implementer. Coordinate its
slot with the parent and recents implementer. All Xcode, simulator, native UI
driving and bundled resources remain with their existing owner.

## Shared activation checkpoint

`WorkspaceModel.activateDestination(_:workspace:generation:)` installs a freshly
resolved destination. `requireNavigationReady(workspace:generation:)` exposes
the common workspace/generation and write/Undo/saved-view busy checks for the
separate direct-record opening path, which preserves the current query.

Four new test functions cover six actual JSC cases. The activation scaffold
failed with five behavioral issues before implementation; eight semantic mutants
were caught afterward. The restored full SwiftPM run reports 240 tests in 43
suites, with five existing live-fixture tests skipped. Palette UI remains the
next implementation step.
