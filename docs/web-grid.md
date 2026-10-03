# Inline record grid

The web grid uses `virtua/svelte` for rendered rows. Database requests retain the
existing 50-row pages. Virtualization does not download every row, provide a
global row count, or change shared-core query semantics. The stress fixture
renders 10,000 synthetic in-memory rows to check bounded DOM work.

`RecordGrid.svelte` owns a cursor identified by row ID and column, with a single
cell draft held outside the virtual row. `FieldEditor.svelte` supplies the same
typed inputs to cells and the record panel. The host provides option/reference
lookups, display labels, editing availability and these callbacks:

- `onbegin(cell): Promise<Row | false>` reads a fresh full row and checks the
  current record draft. False means cancelled or superseded.
- `oncommit(draft): Promise<Row>` writes the changed cell using the captured
  row revision. A rejection keeps the original input and revision.
- `onopen(id)`, `onnew()` and `onduplicate(id)` return whether the guarded
  record action opened. New and duplicate open unsaved creation forms.
- `ontrash(id)` reads the current full row before writing trash or restore with
  its captured revision. `canTrash` is separate from creation availability, so
  Trash can offer Restore. Cancelled confirmation and rejected writes retain
  the cell draft; only a successful receipt clears it. Session Undo remains
  the host's responsibility.

A cell draft contains `{ cell: { rowId, column }, baseline, raw }`. Its parent
binding participates in navigation/unload guards. Pending writes lock navigation.
Saved-view projections and rendered labels are never writable row snapshots.
The host sends one changed property and `expectedUpdatedAt` through the shared
writer. It does not rebase a retained draft after a conflicting refresh. Core
continues to validate catalog types, references, revisions and rules.

Arrow keys move the cell cursor. Enter opens the cell editor. Escape commits;
Discard explicitly abandons its draft. Tab commits before moving right and
Shift+Tab moves left. Cmd/Ctrl+Enter commits before opening the record. Native
picker and rich-editor interactions keep their own key handling. Failed saves
keep focus in the editor; subsequent Tab/Shift+Tab moves through its controls,
including Save and Discard, without retrying the rejected write. The first Record column remains visible in the column
configuration; system, generated, deprecated and immutable fields remain locked.
Numeric inputs preserve incomplete values for the shared writer to reject;
empty or whitespace-only numeric values serialize as null, never zero. Missing
rows or removed properties retain the cell draft outside the virtual row.

Duplicate reads the current full source row and copies user-settable creation
values, including set-once fields. IDs, timestamps, derived and deprecated values
are excluded. The copied form is unsaved until Save record succeeds, allowing
review of required fields and uniqueness conflicts.

## Verification

Run `bun run test`, `bun run check`, `bun run --cwd apps/web lint`, and
`bun run build`. The browser runners require an exclusively leased CDP window
with one owned workspace page on the reserved grid origin and a Vite server:

```sh
LIFE_UI_TEST_URL=http://life-ui-grid.localhost:5228/workspace?review \
  bun scripts/test-record-grid.ts /path/to/life-data
LIFE_UI_TEST_URL=http://life-ui-grid.localhost:5228/workspace?review \
  bun scripts/test-grid-components.ts
bun scripts/test-grid-mutations.ts /path/to/life-data --unit
bun scripts/test-grid-mutations.ts /path/to/life-data --browser
```

The OPFS runner uses a disposable real hub and actual Worker/SQLite operations.
The component runner creates and removes a temporary route in `finally`; it is
not part of the shipped app. Mutation runners restore each source in `finally`.
Never run parallel CDP clients: native confirm dialogs are browser-wide even
when origins differ. Remove the owned test storage, browser group and server
when verification finishes.

Session Undo reconciles a changed cell on the affected row into the record review
panel. The undo receipt becomes the full saved baseline; only the cell's newer
raw input is retained. Autosave stays paused until explicit Save. A creation undo
shows the tombstone read-only, with Restore preserving that draft. An unchanged
cell on the affected row closes and refreshes; a draft on another row stays in its
cell. Failed Undo preserves the cell and its original revision.

The combined enrollment/grid regression uses the separately reserved origin:

```sh
LIFE_UI_TEST_URL=http://life-ui-grid-enrollment.localhost:5234/workspace?review \
  bun scripts/test-grid-undo.ts /path/to/life-data
LIFE_UI_TEST_URL=http://life-ui-grid-enrollment.localhost:5234/workspace?review \
  bun scripts/test-grid-undo-mutations.ts /path/to/life-data
```
