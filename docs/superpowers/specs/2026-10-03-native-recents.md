# Native recents model

LifeKit owns a local preference shared by its iOS and macOS hosts. Store at most
eight successful table/view/row destinations, newest first. Consume the common
`NativeDestination` and `NativeDestinationResolver`; no additional SQL or resolver.
Preserve identifier UTF-8 bytes, including canonically equivalent Unicode strings.

Only the host's explicit `navigationSucceeded` call after its guarded UI commit
records history. Resolving labels, loading, refreshing, failed navigation, saves,
sync and cancellation do not add or reorder entries. The host retains ownership
of draft confirmation, pending-write guards and editor installation.

Persist version 1 JSON containing only destination identities. Use the existing
draft store's stable workspace key under the app's private state root. Local,
external and replica databases remain separate; app-container relocation keeps
app-owned identity. The ephemeral native sample uses a model without a store and
loses its history when closed. No credentials or resolved labels go to disk.

Unread preferences are never overwritten. Storage failures are visible while
in-memory navigation history continues working. Re-read before changing a stored
list so another window's completed additions survive. Use atomic private writes.

Resolve labels and availability through the common fresh resolver. Keep unavailable
destinations with a reason and explicit Remove; absence in a partial replica is
not deletion. Preserve trash state for the host's existing guarded Restore path.
Ignore results after disposal, a newer refresh, entry removal or workspace change.
System grouping belongs to the host and uses only the catalog's `readOnly` flag.

This slice contains new preferences/model files, focused tests and documentation.
It does not change views, workspace integration, generated code, core or resources.
