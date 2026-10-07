# Synced sidebar table pins

Status: requested behavior accepted; detailed design ready for review.

## Outcome

People can keep frequently used tables at the top of the main Life UI navigation
without relying on alphabetical order or device-local preferences. The pin rows
belong to the workspace's synced SQLite data and recover after a fresh replica
sync. No personal choices or table identifiers are seeded in source code.

The sidebar order is Recents, Pinned tables, ordinary Tables, and System tables.
Keep the existing navigation controls above these sections. Pinned tables do not
appear again in the ordinary/System lists; an independently recorded Recent can
still point to the same table. The unpinned lists retain alphabetical ordering
and core-owned System classification. Empty Pinned tables sections are hidden.

Pin and Unpin are available from the table's context/menu action on iOS, macOS,
and web. A new pin appends to the saved pin order. Move up and Move down provide
explicit accessible ordering; drag reordering is optional, not the only control.
Pinning changes navigation preferences only, never the table's editability.

## Storage and core boundary

Use one generic, ordinary synced `sidebar_pins` table with a canonical
DDL/catalog manifest maintained alongside the existing saved-view manifest.
This is user-authored workspace navigation data, not Life UI operational state
in a separate cloud database. It uses the existing Life Data service interface,
validation, history, outbox, tombstones, and sync receipts.

| Column                                     | Meaning                                                                                                                                        |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| id                                         | Versioned deterministic identity derived from the exact target table key; permits concurrent pinning of the same table to converge on one row. |
| tbl                                        | Required catalog reference to the target table.                                                                                                |
| position                                   | Finite integer ordering value. Equal values use byte-exact table-key order as a deterministic tie-break.                                       |
| created_at, updated_at, deleted_at, hub_at | Ordinary sync lifecycle columns, with the normal timestamp trigger; clients never set hub_at.                                                  |

Storage recognition checks the exact supported schema and catalog marker, not
just the table name. An unrelated existing `sidebar_pins` table is preserved and
reported as unavailable. Local/sample workspace initialization may install the
canonical schema; a replica receives its logged schema through the supported
Life Data provisioning/migration path. Clients never silently create or repair
tables inside an enrolled replica. The release includes generic provisioning
support; setup must not require customers to edit the repository or supply
provider credentials to the app.

Generated core operations list pins, pin a table, unpin it, and move it one
position. Hosts use generated DTOs through their existing adapters. There is
no component SQL and no localStorage/UserDefaults fallback pretending that a
failed durable save succeeded. In-memory display caching is disposable.

Pin writes validate the current target catalog identity, recognized storage,
writeability, and exact expected revision in one transaction. Unpin soft-deletes
the deterministic row; re-pin restores it using its current revision. Moving
swaps neighboring positions in one local transaction with both row revisions
checked. A failed check changes neither row. Each mutation returns authoritative
stored rows and only then changes the acknowledged UI state.
If converged rows have equal positions, moving first normalizes the affected
ordered list to distinct integer positions in that same transaction, checking
every row it changes. Unpin remains allowed for a missing target and uses the
ordinary writer's tombstone path rather than requiring a navigable target.

Existing sync is row-level last-write-wins. Independent pin rows avoid replacing
the whole collection when two devices pin different tables. Concurrent offline
reorders can still resolve differently from either local ordering; use the
existing conflict/rejection behavior and deterministic tie-breaking, not a new
CRDT or a claim of globally atomic multi-row sync. Pending synchronization is
visible until its receipt. Only successfully synced pins can be restored after
losing that device's local database; never promise otherwise.

The current catalog table key is also its SQL name. The supported table-rename
transaction must update recognized pin references and rekey the deterministic
pin identity using the existing copy-plus-tombstone pattern. Preserve ordering,
unpin tombstones, and monotonically advancing revisions. Renaming an unrelated
table with the same apparent storage name must not adopt it as pin storage.

## Host behavior and failure handling

The native sidebar model and web sidebar controller combine the current catalog
with ordered pins. Keep their rendering and grouping pure; all persistence lives
behind the core operations. The same rows drive iOS, macOS, and browser clients.
Workspace changes dispose late responses so one workspace cannot display
another's pins.

Pinned navigation uses the same fresh destination lookup, pending-write guard,
dirty-editor confirmation, and successful-navigation history as an ordinary
table click. Pin/unpin controls do not accidentally trigger navigation. During
a pin mutation, disable the affected controls and expose an accessible progress
or error state without closing the active record editor.

An unavailable table remains visible as an unavailable pin with an Unpin action;
do not silently erase it or switch to a similarly named table. A failed pin-list
read retains the last successful display with an error and disables ordering
until a fresh read succeeds. On a new workspace with no prior result, show the
failure instead of assuming the pin collection is empty.

Refresh after a local receipt, sync reconciliation, foreground entry, and
cross-tab database-change notification. No new polling service is introduced.
Recents retain their current behavior; this feature does not migrate history or
change a record's contents. Saved-view pins and stream screens remain separate
from this table-pin implementation.

## Requirements and verification

1. When a person pins a table, the sidebar shall place it below Recents and above
   unpinned tables after the core write receipt succeeds.
2. When a person changes pin order, all three clients shall restore that stored
   order after reopen and after a successful replica sync.
3. When an ordinary table is pinned, the sidebar shall render it once outside
   Recents, while preserving its catalog access policy.
4. If persistence fails or storage is unavailable, the client shall retain the
   prior acknowledged state and expose the failure without writing a substitute
   device-local preference.
5. When the supported rename operation succeeds, the pin shall follow the new
   catalog key through synchronization, preserving order and tombstone semantics.

Start with a real browser UI failure: pin two synthetic tables in nonalphabetical
order, reopen, sync to a second fresh replica, and expect the same pins/order.
Then cover pin/unpin/re-pin, move boundaries, missing targets, storage collisions,
read-only storage, rejected writes, stale revisions, failed refresh, and switching
workspaces while a read is outstanding. Use synthetic actual Worker sync for
cross-replica durability; copying localStorage is not evidence.

Core tests use real SQLite and the normal writer. Python tests exercise the
supported rename with forward-clock revisions, soft-deleted pins, and subsequent
sync. Verify composed/decomposed Unicode and case-distinct catalog identities
stay distinct through Swift and JS presentation where the catalog permits them.

Mutation checks remove persistence, substitute an alphabetical sort, drop a
revision guard, break tombstone restoration, and omit rename propagation. Each
must fail an assertion of observable behavior. Native UI tests then perform
actual sidebar pinning, order changes, reopen, and dirty-editor guarded
navigation. Keyboard and VoiceOver controls are tested without relying on drag.

## Integration boundaries

Life Data owns the storage manifest, validation/operations, generated contract,
rename support, and supported schema provisioning. Life UI imports generated
artifacts and adds native/web models, menus, sidebar sections, and acceptance
fixtures. Core schema and operation changes land before generated client imports.

This delivers the table-pin part of the existing sidebar task. It does not mark
that task complete while saved-view pins or stream/archive screens remain open.
