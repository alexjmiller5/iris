# Native sidebar recents

The shared LifeKit model is independent of SwiftUI navigation. The host supplies
the common `NativeDestinationResolver` and a current-workspace predicate, displays
`entries` and `storageError`, and owns all navigation and draft decisions.

## Integration

1. Create `NativeRecentsStore(root:workspace:)` for a persistent database. Pass the
   application state root and the same database URL used for draft storage. For
   the temporary sample, omit the store; closing the sample loses its recents.
2. Create `NativeRecentsModel(store:resolve:isCurrent:)`. The resolver closure calls
   `NativeDestinationResolver.resolve(_:isCurrent:)` with a current-client check.
   Forgetting a credential keeps the same local database and its history usable.
   Call `refresh()` to resolve current labels and availability.
3. On selection, freshly resolve the chosen `entry.destination` again through the
   common resolver. Respect the host's pending-write and dirty-draft guards. Do
   not navigate using the label projection or a cached row.
4. Only after the host installs the destination successfully, call
   `await recents.navigationSucceeded(destination)`. Do not call it from the
   resolver, a property observer, autosave, sync, default selection or refresh.
5. Call `remove(destination)` for explicit removal, and `cancel()` when closing or
   replacing the workspace. Create a new model for the replacement context.

An unavailable entry remains in the list with its reason. Incomplete replication
is not proof of deletion. Trashed rows retain `isTrashed`; opening them uses the
existing read-only editor and guarded Restore flow. System table grouping uses
only core catalog `readOnly`, independently of recent destination eligibility.

## Persistence

Version 1 stores at most eight newest destination tuples using the common Codable
keys `table`, `view`, `row` and optional bounded `state` query JSON. Identifiers are preserved byte for byte; labels,
record fields, credentials and endpoints are not saved in the preference payload.
The existing draft store derives the workspace key so app-owned paths survive
container relocation and canonical external files remain isolated. Files and
their directory are private, and writes are atomic.

Before each update, the store reads the latest file so another window's additions
survive. A failed read forbids writes until an explicit successful read. At the
model boundary any storage error keeps further changes in memory for that
workspace session, with a visible warning; reopening creates a fresh persistence
attempt. This preserves unread files and keeps navigation available without losing
earlier in-memory visits when a later write happens to succeed.

## Native host

`WorkspaceModel` creates one recents model for each opened local/external/replica
database and cancels it when its client closes or changes. Preference errors do
not prevent the workspace from opening. Foreground and completed sync refresh
recent labels without replacing the editor, loaded rows or query.

`WorkspaceView.recordNavigationSucceeded(_:)` is the single completion hook.
The table, graph, saved-view choose and related-record paths call it after
installation. QuickFind integration must call the same hook after its guarded
destination or pending record editor is installed. Resolving metadata or saving
a view is not a completed navigation.

List row actions use `openRecord(_:)`; MacGrid integration uses the same helper.
It reads the current full row by ID and refreshes catalog metadata while preserving
search, filters, sort and modified saved-view state. Explicit recent/table/graph navigation uses
`activateDestination` to apply the destination's current saved configuration.
Both paths reuse the same workspace-generation and pending-write guard. History
stores the actual applied view ID, never transient query settings.

The sidebar keeps unavailable recents visible with a reason and Remove action.
Trashed entries open in the existing read-only editor with Restore. The System
tables disclosure uses only core `readOnly`, while catalog purpose text appears
under table names. Sidebar navigation is disabled while a modal editor is open,
so it cannot discard a draft; related-record navigation retains its existing
explicit discard confirmation.

The model/store and host-lifecycle tests use temporary files and synthetic
JavaScriptCore workspaces. Actual sidebar layout, compact navigation,
dirty-discard interactions and native accessibility are separate Apple UI gates.
