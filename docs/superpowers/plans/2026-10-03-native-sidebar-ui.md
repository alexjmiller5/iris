# Native sidebar Recents and System tables

Use the shared native destination resolver and activation helper. Keep recents
preferences separate from workspace data and record visits after a successful UI
installation only. The temporary sample keeps history in memory.

## Behavior

- When a workspace opens, load its existing eight-or-fewer identity tuples without
  recording the default table. Use the existing app-owned/external draft identity.
- When a user opens a table, saved view, record, graph table or related record,
  resolve current data, preserve existing guards, install the destination, then
  record navigation. A missing/cancelled/stale lookup must not reorder history.
- While an editor is open, sidebar navigation cannot replace its draft. References
  retain the existing dirty-discard workflow. A trashed recent opens through the
  existing read-only editor and Restore action.
- Opening a row from the current list or grid refreshes the full row and catalog
  but preserves its current search, filters, sorting and modified saved-view
  layout. Explicit recent/table/graph navigation activates the saved destination.
  A recorded visit carries the applied view's stable ID, never transient layout.
- Foreground and completed sync refresh only recent labels and availability.
  They do not force an editor, rows, query or applied view to reload.
- Unavailable entries stay visible with a reason and Remove. A preference error
  remains visible; navigation works in memory without overwriting unread history.
- Core catalog `readOnly` alone places tables in a collapsible System tables
  section. Show catalog purpose subtitles. System tables remain navigable.

## Owned changes and seams

- `WorkspaceModel`: recents lifetime/factory only; consume Galileo's
  `activateDestination(_:workspace:generation:)` without another activation policy.
- `WorkspaceView`: sidebar composition, fresh `openRecord(_:)`, and
  `recordNavigationSucceeded(_:)` after installation. QuickFind calls this same
  success hook; the parent MacGrid calls the same row opener.
- `WorkspaceSidebar`: native sections and accessible row/remove controls.
- `SavedViewsView`: choose-success callback only, after successful application.
- Focused lifecycle/integration tests and documentation; no resources/generated
  code/core/grid/editor changes.

## Verification

Write lifecycle tests before implementation, observe behavioral RED, then GREEN
using real temporary preference files and the bundled JSC workspace. Cover sample
reset, local/external/replica isolation, unread files, explicit completion versus
metadata refresh, close/replacement and fresh labels without row/query mutation.
Add projection tests for core `readOnly`, purposes and byte-exact identities.
Mutation-test lifecycle/recording guards and run the final full LifeKit suite.

Avi owns Xcode/UI verification: table/view/record order and relaunch; sample reset;
dirty cancellation; fresh row/revision and tombstone Restore; unavailable Remove;
System read-only navigation; graph/reference/QuickFind completion; foreground/sync
label changes without bump or draft replacement; narrow iOS and Mac layout,
keyboard/accessibility and purpose subtitles. Compile and actual UI evidence are
separate gates. No Apple UI command is run by this sidecar.
