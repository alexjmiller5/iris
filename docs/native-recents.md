# Native sidebar recents model

The shared LifeKit model is independent of SwiftUI navigation. The host supplies
the common `NativeDestinationResolver` and a current-workspace predicate, displays
`entries` and `storageError`, and owns all navigation and draft decisions.

## Integration

1. Create `NativeRecentsStore(root:workspace:)` for a persistent database. Pass the
   application state root and the same database URL used for draft storage. For
   the temporary sample, omit the store; closing the sample loses its recents.
2. Create `NativeRecentsModel(store:resolve:isCurrent:)`. The resolver closure calls
   `NativeDestinationResolver.resolve(_:isCurrent:)` with the captured workspace
   generation. Call `refresh()` to resolve current labels and availability.
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
keys `table`, `view` and `row`. Identifiers are preserved byte for byte; labels,
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

The model/store tests use temporary files and synthetic JavaScriptCore workspaces.
Host navigation, sidebar layout, System disclosure and dirty-discard UI checks
belong to the later SwiftUI integration.
