# Native incoming references

The model slice adds native consumers of the generated `referenceSources` and
`referencedBy` contract. Shared core remains responsible for catalog interpretation,
SQLite identity, source liveness, target tombstones, labels and completeness.

## Model and bridge

- `NativeWorkspace` decodes the two generated requests through its existing
  serialized request queue. There is no native SQL, alternate DTO or HTTP path.
- `IncomingReferencesModel.refresh()` reads metadata only. Each source is
  identified by its table and column. Opening a group loads 20 rows; subsequent
  pages use the returned `nextOffset` without deriving it from displayed counts.
- A repeated row ID replaces the earlier record and label in its existing
  position. Errors stay local to their group and preserve its rows and offset.
  Row and target-panel identity use exact UTF-8 bytes: Swift String equality
  would merge canonically equivalent IDs that SQLite stores separately.
  Core request IDs retain their original Strings. Table/column identifiers
  remain Strings under the core's ASCII identifier contract.
  Retrying is explicit. A page's source metadata replaces discovery metadata,
  including its `incomplete` value.
- Refresh supersedes pending requests. Disposal is permanent. Both successes
  and failures check request generation, task cancellation and host context.
- `WorkspaceModel.makeIncomingReferences` captures the editor context and view
  generation. Its value identity contains workspace generation, target table/ID,
  the complete catalog and the skipped-table set. Ordinary row revisions and
  unrelated sync counters do not change that identity.

## UI handoff after native UI RED

Production views are outside the model slice. The next slice requires the native
UI owner's Xcode/simulator lease and a failing end-user test before adding them.

1. Mount a separate child in `RecordEditor`'s saved-original branch. Gate on the
   saved ID and current editor context; include read-only records and tombstones.
   An unsaved creation has no panel.
2. Put the new model in that child's `@State`. Apply
   `WorkspaceModel.incomingReferencesIdentity(context:row:)` as `.id` to only
   that child. Leave `EditorTarget.id`, `RecordEditorModel`, the editor's field
   set, and its existing `ReferenceNavigationModel` untouched.
3. Start metadata with `.task`; dispose on disappearance. Reuse loaded groups
   when collapsing/reopening. Offer explicit initial-load and page retries,
   use returned labels, and display `source.incomplete` explicitly even when
   no matching rows are stored. Host skipped-table state is an invalidation
   signal, not an alternate interpretation of core completeness.
4. Send `(group.source.table, row.id)` to the editor's existing `openReference`.
   That route re-reads the full row and retains the source draft on cancellation,
   disappearance or lookup failure. Never open a cached result directly.
   Render rows with `ForEach(group.rows, id: \.byteExactID)`. The default
   `WorkspaceRow.id` String would collapse distinct canonically equivalent IDs.

Native UI cases to establish RED, then GREEN:

- Existing record exposes metadata without eagerly loading every group; opening
  a group shows named incoming records and correct 20-row paging.
- A dirty editor retains exact raw values and field state through catalog
  relabel/removal/reference-target changes and coverage changes. Only the nested
  panel resets. Ordinary body saves retain loaded groups and expansion state.
- New-record creation hides the panel until saved. Read-only and tombstoned
  targets remain inspectable; source tombstones are absent.
- Incoming navigation prompts for a dirty draft, cancellation retains it, and
  approval re-reads the selected source. Missing source rows show an error inside
  the retained editor.
- Failures preserve loaded rows and retry offsets; changed/closed contexts ignore
  late replies. Partial coverage stays explicit after reopening offline.
- Two source records with canonically equivalent but byte-distinct IDs remain
  separately visible and independently navigable, including across pages.

## Verification

Use a dedicated SwiftPM scratch/cache root for this worktree. Run the full
`packages/LifeKit` SwiftPM suite after focused `IncomingReferences` tests.
Real JSC/GRDB tests cover typed operations, full rows and labels, pagination,
source/target tombstones, malformed multi-reference JSON and persisted coverage.
Controlled asynchronous tests exercise cancellation and host timing.

`bun scripts/test-native-incoming-mutations.ts /path/to/dedicated-scratch`
runs behavior mutations with isolated SwiftPM caches, writes logs under that
scratch root, and restores the changed source after every case. Run the full
SwiftPM suite afterward to rebuild the restored sources. No Xcode, simulator,
browser or resource regeneration is part of this model verification.
