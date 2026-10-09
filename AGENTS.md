# Life UI

Local-first web and native Apple clients for catalogued life-data databases.
Title: Life UI; slug: life-ui; Apple product: LifeUI. No PWA or analytics.

Preferred table views are synced IDs through canonical `getViewDefault`/`setViewDefault`.
Plain table and record links open the table through canonical `ensureDefaultView`
(the table's default saved view, created when it has none, with no Undo receipt);
explicit view links win. Unavailable preferences keep their notice without rewriting
stored views. Preference changes use displayed revisions, the ordinary writer and
Undo. Links carry only table, view and record IDs, never view settings. Local/demo
setup uses the canonical `view-defaults/v1` manifest; replicas require operator-provisioned
schema and permitted sync scope. View names and personal lifecycle filters are runtime data.

Related-record defaults select a separate saved-view ID through canonical
`getRelatedViewDefault`/`setRelatedViewDefault`. Incoming links apply its filters
and sorting before pagination, retain full live records, and show invalid-pointer
fallback. Hosts supply the selected definition's calendar policy and saved revision.
Local/demo setup uses `related-view-defaults/v1`; replicas receive its logged
schema from the operator. Ordinary table defaults are unaffected.

## Layout and contracts

- `apps/web`: Svelte 5/SvelteKit, Tailwind 4, Cloudflare Worker static assets.
  SQLite runs through wa-sqlite/OPFSCoopSyncVFS in a dedicated Worker. The pinned
  FTS5-enabled JS/WASM pair is in `vendor/wa-sqlite`; regenerate through its Nix
  package and `scripts/build-wa-sqlite.ts`, preserving the matching API/VFS pin.
- `apps/ios`, `apps/macos`: XcodeGen SwiftUI targets consuming LifeKit.
- `packages/LifeKit/Sources/LifeExtensionSupport`: portable generated DTOs, shared
  calendar policy and bounded read-only SQLite extension reader. No JavaScriptCore,
  network, credentials or database writer. LifeKit reexports the portable types;
  `bundle-core.ts` generates their single canonical Swift source there.
- `packages/LifeKit/Sources/LifeWidgets`: App Intents widget configuration queries
  over authorized publications, depending only on LifeExtensionSupport. Calendar
  choices require tagged calendar bindings from the canonical core plan.
  The iOS WidgetKit extension embeds table-title, Today, bounded-count and Quick Add
  widgets; accessories expose only generic labels/counts. App, widget and share
  targets use the configured `LIFE_WIDGET_APP_GROUP`; signed distribution requires
  explicit matching profiles. App Shortcuts are declared in the iOS app target
  (a package-declared provider is not discovered).
- Quick Add, the share extension and Shortcuts stage one protected `quick-add.json`
  handoff in the App Group; captured text never enters a URL. The host installs a
  recoverable editor journal before consuming it and records the UUID in bounded
  `quick-add-receipts.json`, so retried or late deliveries never open a second draft.
  The share extension (LifeExtensionSupport only) puts one URL or text into a
  Quick Add source's display column; only explicit Save creates a row.
- NativeIntegrationSettings holds per-workspace identities only: Spotlight tables,
  the Shortcuts lookup table (default none) and the daily-section widget source.
  Spotlight indexes display titles of enabled tables in a protected Core Spotlight
  index; item IDs are `life://open/v1` links handled by the pending-link banner.
  Disabling a table or forgetting the connection deletes its domains. Look Up and
  Open Today run in the app through NativeIntentInbox. The iOS sidebar's daily
  section reads the Today widget's own publication through NativeWidgetSettings,
  so both rebind the same calendar slots at the configured day boundary.
- Widget source opt-ins are durable private host preferences, separate from
  regenerable App Group publications. NativeWidgetSettings publishes paired list
  and count plans from the opened database; the library scopes them by workspace
  and physical replica identity. Explicit access removal or database replacement
  revokes the old publication; ordinary close retains its offline copy. A failed
  refresh labels previous data stale. Unreadable preferences and link identity
  files stay intact and must not block ordinary workspace use.
- `packages/LifeKit`: serialized JavaScriptCore facade, GRDB adapter, native
  workspace, URLSession transport, Keychain storage and bundled graph island.
- `packages/core`: generated TypeScript declarations and JS artifacts. Core
  implementation belongs to life-data. Regenerate with
  `bun run bundle:core <path-to-life-core/src/validate.ts>`. Never patch generated
  files. Native and browser full-core headers identify the same source SHA-256.
- `packages/core/contract`: vendored canonical schema and deterministic generator
  from life-data. `bun run check:contract` verifies TS/Swift output and the client
  bundle hash without writes. Change the schema in life-data and regenerate the
  bundle; never hand-edit DTOs. Swift `CoreRequests` and TS operation pairs share
  these shapes. Native and Worker boundaries reject a local contract hash mismatch.
- Sidebar table pins use core's ordinary synced `sidebar_pins` rows. NativePinsModel
  and the web SidebarPins controller retain only acknowledged display state;
  never add localStorage/UserDefaults pin authority. Pin controls use selected
  revisions and existing guarded navigation. App-owned sample/local databases
  may install the packaged manifest; enrolled replicas receive logged schema
  through sync. Web refreshes pins on visibility return, not dialog focus.
- `scripts/native-core.ts`: native adapter over the generated shared core.
  It must not become a second validator, view compiler or sync implementation.
- `apps/web/vite.graph.config.ts`: self-contained native graph HTML built from
  the same SchemaGraph component. No external assets or network access.
- `apps/web/vite.editor.config.ts`: self-contained Markdown editor island using
  the same Milkdown component as the web client. `lifeEditor.setDocument` accepts
  a draft ID, source, label and read-only state; `getDocument` returns the live
  snapshot. Native hosts reject stale IDs and collect all live snapshots before record actions.
  Keep Markdown as storage, preserve untouched source, and render imported HTML
  inert. The island has no network, SQL or credential access.
- Retained `/v1/files/<opaque-key>` image references use the enrolled host
  transport. Web uses managed blob URLs; native passes bytes over the document
  bridge and owns temporary Quick Look files. Both refuse redirects. Image
  previews accept at most 8 MiB and produce a static PNG with a maximum edge of
  1024 pixels; original attachment downloads allow 128 MiB. Reject oversized
  image metadata before decoding. Browser decoder allocation remains platform-owned.
  External images stay inert. File viewing never rewrites Markdown.
  Source links resolve through core `resolveSourceLink` and whole-record import
  provenance, then ordinary fresh-row navigation. Text fields containing explicit
  `table/id` identities offer Open record through the same guarded resolver;
  unavailable targets preserve the field and never become external navigation. Unmapped URLs retain an explicit
  original-link action. Cancel or close disposes requests and file resources.
- Offline attachment bytes live in private app/OPFS files, never database blobs.
  Stage/hash all bytes before publishing a canonical `/v1/files/attachments/<id>`
  reference into the ordinary draft. Native directory rename and web atomic manifest
  publication keep unfinished copies private. Existing enrolled file PUT is
  create-only; uncertain replies require actual authenticated GET byte verification.
  Failures retain bytes and expose retry after reconnect. Workspace replacement
  stops upload admission and stale draft callbacks. Catalog type `file` uses these
  controls and the existing retained-file readers; no implicit save or schema edit.
- `scripts`: build and fixture test operations. No credentials or data exports.

Loaded-row export shares the TypeScript serializer in `apps/web/src/lib/export`
with the offline native `record-export.js` resource (`bun run bundle:export`).
Native serialization runs in a dedicated JavaScriptCore context off MainActor.
`WorkspaceModel.captureLoadedRowsForExport(at:)` synchronously copies committed
loaded rows after successful reads for the current workspace, exact query and
catalog. Capture never flushes drafts or reads the database again. Preserve exact
supported values, IDs and raw Markdown; loaded coverage and freshness stay unknown.
Keep retryable paging-prefix validity separate from the latest successful export
request stamp; full refreshes invalidate the prefix before awaiting work. Native
workspace menus open the system destination picker, with CSV metadata saved
separately from the same capture. Exports contain no attachment bytes and provide
no restore operation.

Backup, export and restore (Settings > Backup on native, the sidebar Backup dialog on
web) call core's `exportReplica`, `previewRestore`, `restoreReplica`, `hubBackups` and
`createHubBackup` (life-data `docs/backups.md`). Hosts own files only: web keeps them
in OPFS `backups/<staged|recovery|exports>/` behind the worker's `BackupFiles`
adapter; native passes file paths to `__lifeDump*` bridge functions backed by
`DumpFiles.swift` (gzip inflate with CRC/length check, whole UTF-8 chunks, writes
published on close). Download replica copies the OPFS file while the worker's
connection is closed, or GRDB's backup of the native file; the sample is in memory
on native and has no file. Hub backups download through the enrolled transport
and are checked against the listed size and SHA-256. Restore needs the typed word
`replace`, no open edits and no pending local writes; core writes a recovery copy
first and the newest three are kept as Undo. A CLI-owned shared file shows its
path and `life export` instead. Progress folds into the sync pill.
`scripts/test-backup.ts` drives the web flow against the real hub Worker.

Web row checkboxes select exact IDs on the loaded page. Bulk property changes and
soft-deletes use fresh full rows and revision-checked shared writes, one row at a
time. Preserve separate succeeded/failed/unattempted receipts; cancellation stops
new work but cannot revoke a committed receipt. Do not flush active drafts or
describe this as atomic/whole-batch undo. Workspace/query/catalog changes stop
admission, while the batch's own row-refresh broadcasts retain its frozen IDs.
Selected exports reuse the loaded-row serializer and its coverage metadata.
Native selection lives in the existing workspace menu's loaded-row sheet. Freeze
the displayed capture before presentation; selected exports retain that capture.
BulkRecordModel checks exact UTF-8 identities and revisions, and ordinary model
saves own reconciliation and sync scheduling. Keep cancellation separate from an
admitted write's receipt; closing the sheet stops only remaining work. Do not
invalidate its query/catalog guard on the batch's own successful row refresh.

Native record actions can explicitly open a saved row as a Page Archiver attempt.
The viewer validates canonical metadata without table-name inference, keeps the
selected historical attempt immutable, and uses the current enrolled host's file
reader. Verify declared size, MIME and SHA-256 before preview or save. PNG is the
default bounded preview; partial warnings and unsupported original URL text remain
visible. Preview refusal does not invalidate the retained capture. Save PNG/HTML
uses the system destination picker with exact original bytes, cancel and retry;
opening the viewer never flushes an editor draft. Workspace changes cancel its
requests. Archived HTML uses a separate nonpersistent WKWebView, an opaque sandboxed
child document, restrictive CSP, a content rule list and navigation denial. Native
context gestures are intercepted before WebKit's internal content view can offer
external actions. Saving HTML never automatically opens it.

The web saved-row action mounts PageCaptureViewer with an immutable explicit row
and the existing enrolled file resolver. Each action reauthorizes and verifies MIME,
bytes and SHA before use. HTML is previewed only in an empty-sandbox iframe with an
early restrictive CSP; inert template parsing removes navigation surfaces before
mounting. Never grant same-origin/scripts, rebase links or forward credentials into
the archive. Closing or replacing the host invalidates all outstanding work.

The supported service dependency is the life-data hub API with independently
minted client credentials. Never bind its D1/R2 or borrow infrastructure tokens.
Life UI owns its Worker, Access application, vault and deployment credentials
when provisioned. `.env.tpl` is the operator/CI bootstrap manifest; its values
never enter the browser bundle. Workers Scripts Write is account-scoped in
Cloudflare; `scripts/provision.py` mints Life UI's own token during bootstrap.
Pushes to main deploy the web Worker through `.github/workflows/deploy.yml` once
bootstrap has set `OP_SERVICE_ACCOUNT_TOKEN` (until then the job skips with a
notice). Cloudflare Access protects the Worker's hostnames; converge it with
`scripts/cf-access.py`. The public repository is `alexjmiller5/life-ui`.

Apple validation uses `macos-latest`; signing workflows use standard
`macos-26-intel` hosted runners. Mac distribution
uses `.github/workflows/release-macos.yml`, triggered only by
explicitly approved stable version tags. It stamps the tag version, builds both
Apple Silicon and Intel, exports with the existing Developer ID certificate and
an app-owned distribution profile, notarizes, staples, checks Gatekeeper and
publishes the archive before updating the configured Homebrew tap. Xcode resolves
the private App ID from that profile; no shared Keychain groups are requested.
Before publication, both signed architectures must match the profile and selected
certificate, and a separate signed probe using the production HubCredentialStore
must pass Data Protection Keychain create/read/update/delete with a unique
synthetic service. Never replace this gate with signature validity alone.
The tap is a separate job so its failure never requires republishing an asset.
It only advances stable versions; identical version/hash retries are no-ops,
while conflicting hashes or unsupported version/checksum formats fail closed.
The documented Apple Signing vault exception supplies shared signing/notary
material and the tap credential to the project CI service account. This grants
CI read access to that shared vault; it is not app runtime or consumer auth.
`HOMEBREW_TAP_REPOSITORY` and `MACOS_PROVISIONING_PROFILE_ID` are repository
variables, not client preferences. The latter is the stable App Store Connect
API ID of Life UI's MAC_APP_DIRECT profile. Release CI only downloads it;
profile creation/renewal is an operator action using the existing signing
certificate. Never expand cloud-signing permissions or mint replacement
certificates to compensate for a missing profile.
Ordinary changes never bump a version or push a release tag.

iOS Ad Hoc distribution uses the manual `build-ios.yml` workflow with existing
Apple Signing distribution material and the project CI service account. It downloads
one explicit `IOS_APP_ADHOC` profile per target with the existing App Store Connect
key: repository variables `IOS_PROVISIONING_PROFILE_ID` (app),
`IOS_WIDGETS_PROVISIONING_PROFILE_ID` and `IOS_SHARE_PROVISIONING_PROFILE_ID`.
`scripts/sign-ios.py` maps each profile to its target by exact App ID, requires one
team, device, shared certificate and the App Group set declared by every target's
entitlements file, and checks that each declared entitlement (production APNs on the
app, `LIFE_WIDGET_APP_GROUP` everywhere) is granted and survives export. project.yml
names the profile settings `IOS_PROFILE` and `IOS_<BUNDLE SUFFIX>_PROFILE`. It also
checks the intended `IOS_DEVICE_ID` project ENV field, signs using a temporary runner
keychain, verifies app and extension versions match, and uploads only age-encrypted
output with one-day retention. The required `artifact_recipient` dispatch input is
a public age recipient; its temporary private identity stays with the operator.
App Group assignment to App IDs is a developer-portal step; profiles are minted
afterwards with the existing distribution certificate. The universal app App ID is
shared with the Mac Developer ID profile, so a capability change requires replacing
`MACOS_PROVISIONING_PROFILE_ID` as well.
An IPA embeds a profile containing enrolled device IDs, so plaintext IPA artifacts
are forbidden on this public repository. Each workflow run stamps and verifies
the exported build number as run.attempt after project generation. OTA manifests
use that build number, with distinct install-page, manifest and IPA URLs; the
status sheet reads the installed app's version from Bundle.main. Installation
and OTA remain separate.

Shared core owns local FTS5 indexing and search. Web table search and Cmd+K use
literal word prefixes combined with AND; user input never becomes raw MATCH
syntax. Index queues survive external edits and reopen, and index updates run
inside the same serialized request as the query. No client scan fallback or
parallel search implementation. Cross-table results carry table/id identities;
opening one must re-read it, respect unsaved drafts and ignore a cancelled dialog.
Search covers locally replicated rows and identifies skipped-table incompleteness.
The web command palette also lists tables and saved views. Read saved views once
per opening through the core, preserve selection by kind/table/id as entries
arrive, and re-resolve destinations before navigating. Closing cancels late replies.
Selected relation actions share the guarded full-row opening path. Navigation
stays separate from editing/removal permissions, and skipped tables may still
contain navigable local rows. Preserve the source editor on unavailable targets
or canceled discard; stale lookup successes and errors must not change context.
Editable ref/multi_ref pickers offer Create "<text>" when the trimmed search has
no exact loaded name. Targets must be writable with a non-derived display property
(`reference-create.ts`, `ReferenceCreator`). Creation uses the ordinary writer:
untouched catalog defaults are omitted for core, required fields without defaults
open a target-table editor first (dialog on web, sheet on native) and Cancel writes
nothing. Only the receipt's exact id enters the source draft (multi_ref appends);
the source still needs its own Save. Writes are local, sync later and join Undo.

Web recents store at most eight table/view/row identity tuples per workspace,
with labels resolved from current local data. Record only completed navigation;
preserve unavailable entries with a reason and an explicit Remove action.
Preference read failures must not overwrite the unread stored history. System
table grouping uses core catalog `readOnly`, never host naming conventions.
Native destination resolution reads fresh catalog, saved-view metadata and full
active or trashed rows through the same core. Keep exact UTF-8 identities after
SQL lookup, including databases with case-insensitive ID collation. Native recents
persist only destination tuples; their model records a visit only after the host
commits navigation. A failed preference read keeps new visits in memory and must
never replace unread history. The temporary sample uses memory-only recents.

Native Quick Find combines table/view metadata with the existing record search.
Discover metadata once per opening except for explicit retries, keeping paging
and metadata failures independent. Retain selection by exact destination identity
as results arrive, and keep unavailable choices visible with their reason.
Resolve every choice freshly before host activation. Closing disposes both reads;
record navigation is recorded only after the pending editor actually installs.

Web destination URLs carry only table, stable saved-view and record identifiers.
Resolve them against the explicitly opened workspace's fresh catalog, saved view
and full row. Use SvelteKit navigation hooks for browser history so cancelling
Back restores the URL as well as the draft. Do not use shallow history entries
that bypass those hooks. Ignore superseded lookup replies and block writes while
resolving a linked record. Unsaved view settings and credentials stay out of URLs.

Native `life://open/v1` links follow `docs/native-deep-links.md`. Receiving a URL
only fills the single pending-link banner; it never opens, enrolls or switches a
workspace. Open requires the same idle state as Find, matches the retained binding
and reuses `openDestination`; clear the request only after the destination
installs, and keep it with its error otherwise. Copy only after encoding and
identity persistence succeed. Native Duplicate reads a fresh full active row into
a new prepared editor, confirms discard only for a dirty source, and removes the
unused copy's journal when the user keeps editing.

Manual Resolve uses the core's revision-checked `resolveDerived` operation on the
bound hub, followed by ordinary replica sync and a fresh full-row readback.
HTTP-derived fields remain read-only. Require a saved, clean record before the
request, collect retained native Markdown first, and preserve late input against
the readback baseline. Display provider failures without claiming success.
Never write provider results directly into the replica or implicitly save a draft.

Saved views use the core contract and the canonical `core/schema/saved-views.json`
manifest vendored by `bundle-core.ts`. Only explicit app-owned local/sample
initialization may create missing storage; replicas receive logged DDL through
sync, and external files or name collisions are never adopted or repaired.
The core bundle source hash includes the manifest. Keep the applied view's
revision until the user reopens it, even when a refreshed list has a newer one.
Definitions control layout; edit queries must return full rows, not the
saved definition's SQL column projection. Preserve imported multi-column sorts.
Native Properties controls edit ordered visibility through that same definition.
The configured table display column stays prominent, while hidden fields remain
in the editor draft and are reachable through More properties. New required
fields and validation failures stay visible. A title-only saved view keeps a
catalog-valid title or ID column because core rejects empty projections. Resetting
layout removes the projection; it never removes record values or resets widths.
Mobile property editing and the full record pop-up share RecordEditorModel and its
recovery journal. Resolve a fresh full row and field editability before inline
editing; immutable/derived fields and recovery use the full presentation. Expand
transfers the existing model, never a reconstructed draft. Full records embed visible
Markdown bodies below their properties. Retain one WebKit holder per exact field
ID through form recycling; collect all holders before save, close, Undo or record
handoff. Terminal close retains stopped holders through sheet dismissal; inline
expansion transfers the live holders with their record model. Explicit
Undo/recovery transitions refresh sessions; ordinary draft
updates must never replace undelivered WebKit input. Keep the active row
visible during background refresh and prevent context-changing actions until close.
Empty-property grouping never hides zero, false, required creation fields or
validation errors, and stays stable while the editor's values change.
Image previews preserve editable source. Only retained file keys use hub auth;
external HTTPS requests are credential-free and refuse redirects. Bound downloads
and decoding. SVG renders as an inert data image inside a network-disabled WebKit
view, never as an executable SVG document. Do not infer personal column names.

Saved-view IDs also require byte-exact list and selection identity. Use the
applied revision for deletion only when its ID bytes match the chosen view.

The usage/notifications API is owned by life-data; never add competing hub
endpoints here. life-core owns service validation, feed pagination and presentation
policy. Isolate cached state by signed-in deployment, deduplicate native/feed
alerts by event id, and never expose bearer tokens in device lists. First contact
baselines history; delivery checkpoints advance after successful scheduling.
Persist alert IDs byte for byte and compare their UTF-8 bytes; Swift String
sets can collapse distinct event IDs. Checkpoint files retain their JSON arrays.
Notification and usage-device rows also use byte-exact keys. Keep the original
event IDs in mark-read requests.
Native permission is requested only by the explicit Enable alerts action. Native push registration uses the
existing authenticated transport and the canonical `apns-registration-v1`
capability. Public profile discovery only offers an explicit browser approval
link; it never grants authority or replaces the existing credential. The app
delegates deliver opaque OS tokens to the current session helper. No provider
facts or signing credentials belong in the client. Readiness is volatile, bound
to the current token and exact UTF-8 deployment/session/profile identifiers. The
existing alert preference remains authoritative across windows. Server revision
checks own retries and installation state; do not add a parallel client store.
Before a registration write, retain an attempted-registration hint in the existing
alert checkpoint. Forget resolves server state whenever that hint is present;
disabled local alerts alone do not prove revocation. Never-enabled connections
remain forgettable offline.
Usage is deployment-scoped; provider-wide billing APIs do not belong in clients.
Registered push owns banners; polling continues to update the inbox. Suppress
local banners only after an authenticated registration receipt matches the current
deployment, session, installation and token generation. Rotation, logout and
replacement invalidate readiness. After every awaited permission or scheduling
operation, recheck the current binding and merge fresh alert preferences and exact
delivered IDs so another window's disable or successful delivery is preserved.

## Data integrity

Components call the shared write path; no component SQL writes.
Typed web link actions are presentation only: keep the original draft text,
restrict websites to HTTP(S), encode email recipient text and reject phone
service codes. Keep open actions available on read-only properties and isolate
external tabs from the editor. Malformed source must not break rendering.
The SQL adapter read path accepts exactly one read-only statement. Parse the
whole input before stepping; reject writes and connection-changing commands
from catalog options/default expressions. Trusted schema replay stays separate. Pass the opened
record's `updated_at` as `expectedUpdatedAt` to prevent stale editor overwrites.
Keep drafts separate from the stored row and reconcile successful writes without
silently discarding later typing. Web body autosave writes only editable Markdown
columns on existing rows; it updates the acknowledged baseline without replacing
the live draft. Failed identical patches must not loop. Preserve unknown existing
multi-select values.

The web view toolbar holds the view switcher (its menu renames, copies, deletes and
sets defaults), Filter, Sort and layout. Filter chips edit `filter-bar.ts` rules:
operators come from the property type, several checked options save as an any-of
group (none-of for "is not"), other groups stay advanced chips, and rules without a
value are never saved. Every view change applies to the query at once;
`createViewAutosave` captures the applied view synchronously and saves it through
ordinary `saveView` with the latest revision this tab wrote, after edits settle and
never while a filter or sort popover is open. Context changes, unload and Undo
flush it first, so Cmd-Z reverts the latest view edit. Search and Trash are browsing
state and are not saved.

The native `FilterBar` (iPhone and Mac) sits above the records with Filter and Sort
popovers and a chip row. Filter is a searchable property list (Add filter group
inside) that adds a chip and pushes its type editor: select options as checkmarks,
text, number, date with Today, Boolean and the existing reference picker. Chips edit
on tap and remove with x; Sort holds ordered rules with direction toggles and drag
reorder. Edits apply to the query at once; chips without a usable value neither
filter nor save. Closing a popover or the Views sheet, or removing a chip, calls
`WorkspaceModel.scheduleViewSave` (400 ms). It captures the request, so navigating
away still saves the view it was made in, uses the applied revision and ordinary
`saveView` (Undo) and keeps the stored search and Trash. Close and Undo
(`undoLatest`) flush it first. Layout heads the Views sheet; row actions and the
Today boundary live under Row actions and Today. All records appears only when the
table has no available saved view.

A Boolean property whose catalog description names exactly one sibling text column
is a flag with a reason (`flag-filters.ts`, `CatalogField.flagFilters`). Web and
native bars offer it as a dashed quick-filter chip that adds the ordinary `eq true`
rule (saved like any chip); while it is on, the reason column shows beside each
record. Search hits from a table with a `status` select (life-data's status
dictionary) show that status with its catalog option description as help
(`search-status.ts`, `QuickFindModel.statusFields`). No lifecycle word is hardcoded.

Saved view version 2 supports bounded all/any groups, host-resolved Today,
ordered option/value sorts, literal row actions and interleaved action columns.
Preserve every clause and source order when editing or reopening. Browser Intl
and native Foundation resolve the saved timezone's configured local day boundary,
defaulting to midnight, and refresh there and on foreground entry. A missing local
time advances to the next valid instant; repeated times use the first occurrence.
The shared JSC core has no Intl.
Calendar contexts are query arguments only, never persisted in definitions.
Actions use the generated runRowAction operation with the selected full row's
post-save revision and the applied saved-view revision. Disable them during writes
or while view settings are unsaved. Core
resolves the current saved action, validates its ordinary write and publishes
undo only after commit. Local receipts remain subject to sync rejection.

Native catalog choices load through `NativeWorkspace.options`; controls only
change draft bindings. Keep selected unknown choices and exact UTF-8 option keys,
and expose malformed multi-select source for explicit repair. Late option replies
must not replace a closed editor's state. Date controls preserve untouched source
and use explicit UTC for datetimes; invalid values never silently become today.
Link actions require explicit taps and supported schemes. Core remains the only
validator and writer.

Human Undo uses the core's bounded session stack of 100 validated receipts. Display the action as
"Undo last saved change" and submit that displayed receipt ID; never reconstruct
inverses or expose history as undo. Pause body autosave before the request without
flushing the draft. Merge unchanged fields from the returned row while preserving
newer drafts; those drafts require an explicit Save before autosave resumes.
Failures retain the draft and action. A returned tombstone stays read-only until
explicit Restore, which also preserves the retained draft. Text-editor Undo stays
separate. Cmd-Z/Ctrl-Z outside typing controls dispatches the current receipt; never
steal text-input or Markdown undo. Successful Undo exposes the preceding action.
Saved-view changes join the stack and explicit Undo refreshes their list and applied
revision. Reopening a workspace clears the stack.

An affected dirty grid cell moves into the record review panel after Undo,
using the receipt's full baseline plus only the newer raw cell value. Clear an
unchanged affected cell; leave another row's cell draft untouched. Creation Undo
retains the draft beside a read-only tombstone, and Restore preserves it.

Governance presentation imports generated Life Data DTOs. The panel remains
unmounted with no API or journal injection until service operations and capability
advertisement are verified. DTOs and the pure inverse planner do not authorize
client previews or writes. Keep the original approval request/key after an uncertain
response; only a matching committed receipt, purged result or authenticated durable
`not_committed` result can settle it. HTTP classification belongs to the core adapter.

Web related-change review uses the separate `bounded-changeset-proposals-v1`
capability and canonical core client. Only an enrolled USER approval connection
can open it; drafts and pending local edits must be resolved/synced first. The
panel reads a supplied proposal ID, displays the entire frozen set and never
writes SQL or edits its operations. Its journal captures endpoint, deployment,
session, principal, full proposal and original request before dispatch. Closing,
auth failure or an uncertain response retains the same key; only a validated
whole-set receipt, purge or durable negative result clears it. A completed hub
approval requires ordinary sync to update local rows. Shared IndexedDB storage
uses strict durability and compare-delete, with immutable captured scope codecs.
Native multi-row review is not mounted. Single-row presentation retains its
separate existing boundary.

Native recovery journals are private, atomic and isolated per editor. Persist
the latest draft and any unacknowledged write before awaiting its receipt.
Keep new-record defaults omitted until a field is explicitly edited. An explicit
clear is null, while copied SQL empty text stays an empty string; unchanged
Markdown snapshots do not count as edits. Duplicate preparation uses a new
nil-recordID journal, preserves older variants and never writes a database row
before Save.
Keep app-owned workspace identities stable across container relocation; external
databases use canonical paths. Recovery never rebases an old draft implicitly.
Copy/review into a fresh editor or explicitly discard the retained draft.
Record and reference IDs are opaque UTF-8 values. Native equality, collection
keys and SwiftUI row identity must preserve their exact bytes; Swift String
canonical equivalence must not merge records, recoveries or reference selections.
Keep the original String values at the core boundary.

Whole Worker requests are serialized. Native instances opening the same physical
file share request admission, including initial schema repair; independent
files and memory databases keep separate admission. Foreground local operations
may pass only a trailing run of passive reference-label reads, preserving order
among foreground operations. Sync, close, transport-bearing requests and
transport continuations remain ordering barriers. Passive label callers wait
outside the database queue, with at most one submitted
reference read per workspace. This prevents a service or sync barrier from trapping
foreground navigation behind a whole label backlog. Canceling an unsubmitted label
releases its waiter; an admitted label keeps its transaction ownership. Canceled queued
catalog/row reads release their reserved file turn without entering SQLite;
an admitted request always finishes its transaction and callback. Resolve symbolic links before
opening and refuse hard-linked database files so journals have one identity.
Native workspace diagnostics are bounded in-memory timing records, copied only by
explicit user action. Use fixed operation enums, process-local IDs, durations,
counts and byte totals; never record SQL, arguments, table names, errors, URLs,
credentials or content. Snapshotting must not enqueue database work or observe
per-statement updates in SwiftUI. Network suspension remains distinct from local
execution, and post-request DTO decoding attaches to the same retained receipt.
Native requests retain SQLite ownership
across every transaction and local await. HTTP outside a transaction suspends
its request owner so complete foreground requests can run; the HTTP continuation
resumes through that same queue, never inside another request's transaction.
Close refuses new HTTP and cancels every outstanding transport (sync, services,
Resolve, online reads). SQLite closes only after suspended owners unwind; any
still suspended after a 5-second grace is failed and reported as dropped, so close
never waits on the hub. Queued duplicate syncs do not block eligible foreground
requests before close. Keep the sync file lock while suspended.
Native destination waits stay visible outside scrolling content and offer Cancel.
Cancellation invalidates only the navigation request and immediately releases its
controls; late results and old defers must not affect a newer request. It never
cancels sync or removes a core continuation. Canceled reloads preserve displayed
rows and errors. Admitted sync and committed mutations own their awaited model
reconciliation, with fresh workspace/query guards, independently of scene-task
cancellation. Sync has read-only progress, cooperative transport cancellation
(used by close) and a 15-minute round deadline; there is no manual sync action.
The scene's single foreground task pulls on activation, then every 2 seconds while
active and online. The system path monitor pauses it offline and pulls at once
when a path returns; background scenes stop it. Successful local record/view saves
and undo debounce catch-up by 750 ms; edits during a round queue another round
after its receipt. Failure delays automatic retry by 60 seconds until the next
activation or reconnection. A round that moved nothing and left the catalog
unchanged refreshes only writeability and status counters, never rows, recents,
pins or the inbox. Workspace/session guards cancel obsolete timers. No closed-app
delivery is implied.
Native SQLite connections force `legacy_alter_table=OFF` so logged renames
rewrite trigger/view references consistently across hosts. Recovery repairs only
an exact canonical timestamp trigger whose direct table rename is in the local
schema log and whose old table/view name is absent. It changes no rows, pending
edits, or log entries; custom triggers and unproven renames stay untouched.

Native SQLite transactions retain ownership across awaited JS callbacks.
Browser operations hold a Web Lock across tabs; native sync holds the
Python-compatible `<database>.sync.lock`. A demo database must never sync.
Application state lives in OPFS/Application Support, never the source checkout.

Core system tables and `catalog_tables.kind: system` are read-only. Hosts use
the shared `writeability` advisory and display its reason, invalidating stale
answers on workspace/table changes and refreshing after failed sync too.
The writer rechecks every mutation transactionally. Table SQL invariants require
core-certified coverage of their validation dependencies and catalogs. Hosts
provide compiler-derived `readDependencies` on the same connection/transaction,
without executing the supplied statements. SQLite authorizer reads and GRDB
regions include view dependencies; never infer this set by parsing SQL text.
TEMP context ownership comes explicitly from core, not an object's name.
Unknown metadata, attached databases and unsupported storage fail closed.
Adapters without this capability retain the full-global-coverage check.
Ordinary cursors or imported files do not certify completeness.
Custom triggers, declared SQLite FKs and enforced estate rules fail closed.
Missing replica references must not be guessed valid.
The browser incoming panel uses generated `referenceSources`/`referencedBy`,
with metadata-only discovery and lazy 20-row groups. Keep group errors visible,
preserve the offset on retry and deduplicate page IDs. Record/workspace changes
dispose old replies; catalog or skipped-table changes invalidate only the panel,
not the surrounding editor draft. Incoming links use the same fresh-row navigation
and discard guard as outgoing references. No host SQL or inferred reverse links.
Native incoming models decode the same generated operations through NativeWorkspace.
Their panel identity uses workspace generation, target table/ID, catalog values
and the skipped-table set, excluding row revisions and unrelated status counters.
Keep that identity scoped to the incoming child; never recreate the record editor
or its draft when relationship metadata changes. Native requests also capture
view generation so a table round trip cannot revive an old panel.
Incoming row deduplication and SwiftUI row identity use `byteExactID` (UTF-8
bytes), since Swift String equality merges some distinct SQLite record IDs.
Keep the original String ID for requests and navigation.
Native saved-record editors mount incoming references as a separate child section.
Disposal invalidates pending reads without changing rendered section state during
Form layout or sheet dismissal. Reappearance replaces the disposed model, and
expanded groups reload against that replacement. Never attach panel identity to
the editor or reuse a disposed instance.
Group rows use the existing guarded reference navigation and disable opening while
an editor write is pending. Keep accessibility identifiers off an enclosing
DisclosureGroup: SwiftUI can propagate them over individual child controls.
The macOS table uses byte-exact wrapper identities and opens records through the
same fresh-row navigation as the list. Saved columns affect presentation only; an explicit empty list
still leaves the record-opening column. Keep notices and recovery actions bounded
and scrollable so they cannot consume the grid. Native column resizing is temporary;
persisted layout comes from the saved-view definition. The AppKit grid supports
macOS 14 onward. Double-click edits the clicked property in the shared inline
editor; Return edits the selected row's title. The explicit open action and row
menu retain the full editor. Column header menus sort (saved like the Sort popover)
or add a property's filter chip and open its editor.
Keep active drafts and their action controls mounted through catalog/row refreshes;
measure editor height before retiling the row. Disable workspace replacement and
new-record actions while an inline editor is active. Close workspace is always
enabled and dismisses open surfaces itself; edits are already journaled. Property help popovers belong
to their individual buttons.
RecordEditorModel capture preparation retains its handoff UUID in the ordinary
recoverable creation journal. Pending delivery retries preserve edits and refuse
to fork another live editor. Empty captures stay recoverable; only explicit Save
creates a row. Entry-point navigation and workspace/writeability checks remain
the host's responsibility.
Markdown previews parse a bounded prefix off the main actor and never rewrite
source. Only the active cell mounts a rich editor. Its prepared record model owns
the live WebKit view across table recycling; dismantling a cell is not an editor
close. Collect a locking snapshot before save, expand, cancel or keep-draft, and
release the host only when the authoritative draft presentation closes. A locking
snapshot wins over delayed intermediate change notifications; nonlocking background
reads still preserve later received changes.
Skipped-table data can be incomplete and the UI must identify that state.
Use core status `skippedTables` after reopen, including offline. Core persists
the last completed pull's exclusions even when pushes are rejected; hosts never
write that state or infer completeness from download preferences.
Online browsing calls generated `remoteRows`/`remoteRow` through the same
serialized adapter. The core checks the durable endpoint binding before HTTP
and rechecks schema/binding after it. Hosts supply the active connection, never
draft credentials. Keep online rows transient and read-only; never merge them
into local rows, FTS, cursors, coverage or pending edits. Preserve server paging
cursors when deduplicating IDs, re-read a selected ID, show tombstones, and
invalidate late replies on close or workspace/connection changes. Caps are
shown without automatic retries or alternate routes.
Web rejected edits come from the generated core `rejections` operation, never host SQL
or JSON decoding of bookkeeping tables. The inbox loads 100 at a time and shows
the independent status total. A malformed page remains visible with Retry, keeps
loaded entries and its offset, and never deletes stored data or blocks opening
local records. Reset paging after a refreshed snapshot; ignore replies from older
snapshots or closed workspaces. Review uses a fresh full local row and its revision,
with rejected values held as a draft and autosave paused until explicit Save.
Tombstones remain read-only until Restore, preserving that review draft. A saved
correction stays in the inbox until sync accepts it.
The native inbox model uses the same generated read operation and keeps its status
total optional until that read succeeds. It pages by core offsets, preserves exact
UTF-8 table/row identities, and requires a workspace-current closure plus disposal
on close. The workspace Issues sheet owns refresh, paging and disposal, including
refresh after sync and reopening offline. Prepare the review against fresh catalog,
full row and writeability before dismissing Issues. Recheck workspace, query and
request identity after dismissal, then install the already-persisted editor and
record recents. A cancelled handoff keeps its journal and never changes navigation.
Prepare rejected values with `RecordEditorModel.installRejectedDraft` on a fresh
editor before changing navigation. It preserves the current row/revision, copies
only loaded editable fields and persists a distinct, paused journal. Keep existing
recovery variants; never resume an old journal to obtain a fresh rejection review.
Journal failures abort presentation. Explicit Save and Restore use the normal
writer; only accepted sync receipts remove durable inbox entries.

Pending UI edits await the core's own valid receipt; this is not the CLI queue.
Never report a write as saved or a round as synced before its promise succeeds.
Web sync failures also broadcast database changes: individual pulls and receipts
can commit before a later request fails. Refresh rows, counts and writeability
in every open tab while retaining editor drafts and the original sync error.
Connected web workspaces sync by themselves through `sync-status.ts`: push 750 ms
after a committed write (worker `change` events carry the method, so other tabs'
writes count), pull every 2 s while visible and online, wake on visibility, focus
and online, one run at a time, backing off to 60 s on errors. One visible connected
tab holds the `life-ui:sync-leader:<database>` Web Lock; hidden tabs release it. The
worker broadcasts a sync only when it pulled, pushed or rejected rows, so idle polls
never refresh views. `SyncStatus.svelte` in the sidebar is the only sync/save status;
add no sync or refresh buttons, progress bars or save notices. Cmd/Ctrl+\ toggles
the sidebar, persisted per device in localStorage.

Credentials cross the supported client seam as a hub URL and app-issued token.
Browser tokens are session-only; native tokens use Keychain.
Browser enrollment consumes generated core approval/session/poll/revocation
operations. Hosts own Web Crypto (24 random bytes plus SHA-256), monotonic timing,
fixed bounded GET/POST session transport and cancellation. Never duplicate core
identity or replica eligibility policy. Check the existing main-schema core and
Python hub bindings before showing an approval link or sending session credentials;
sync rechecks its authoritative binding before transport. Reject late results
on cancellation, timeout, replacement or workspace closure. Publish a validated
replacement connection only after sync succeeds or its exact cap response, and
preserve the current connection on failures. Cancel attempts cleanup only for its
own candidate; unauthorized is not revocation proof. Approval URLs carry a hash,
never a bearer. Manual credentials use the same core session validation. Provider credentials
stay service-side. Native SQL callbacks are trusted JSC-only, never exposed to
web content. WebKit input uses parsed arguments and validated messages; the graph
resource forbids navigation/network and contains its own script/style CSP hashes.

Native enrollment generates a candidate credential locally and opens the hub's
approval URL containing only its fingerprint. Shared core validates approval,
session identity, full device scope and replica capability before Keychain or
workspace replacement. Operator credentials never become consumer sessions.
Cancellation revokes only the generated candidate when possible; it must not
remove an existing connection or claim an unused approval URL was revoked.
Established Keychain replicas reopen offline before a sync attempt. Keep the
canonical enrollment fixture synchronized through `bundle-core.ts` and execute
it in JavaScriptCore as well as the core's own tests.

Saved views can select Calendar, Gallery or a select-grouped Board. Keep these
settings in the canonical v2 presentation object. Calendar and Board layout use
shared core operations over loaded rows; hosts supply existing civil-day bounds
and display pagination coverage. Date-only range ends are inclusive; timed ends
are exclusive. Board moves use normal revision-checked writes and the same draft
and read-only guards as other edits. Gallery covers use the selected catalog
property and the existing separate retained/public image credential paths.

## Development and verification

`bun install --frozen-lockfile`, then `just dev`. `just test`, `just check`,
and `just build` cover web and Apple targets. `just fmt` formats owned source.
The README documents browser smoke commands and a real Worker synthetic hub.
Fixtures are synthetic only; never copy live personal data into tests or docs.
Run the package suite with `swift test --no-parallel`: independent MainActor/JSC
fixtures otherwise starve each other’s admission watchdogs. Keep explicit
concurrent tasks inside tests and their assertions unchanged.

`project.yml` is authoritative; generated Xcode projects and Info.plists are
ignored. Child justfiles expose platform run/test/check/build. Caches and derived
data live outside the synced source tree with environment overrides. Do not
open Xcode on a headless build host. Simulator tests can use local signing;
unsigned builds need no Apple account. Ad Hoc, phone installation, Developer ID,
notarization and installed distribution are separate verification steps.

Test behavior before implementation, then verify real SQLite, JSC and browser
flows. Run the full applicable suites after the final source change. Use an
isolated simulator if another project is driving the shared default device.
iOS record screens use inline navigation titles and no extra top list content
margin; keep title, controls and first list row separate and compact.
iOS uses native bottom toolbar actions for Views, Find and Schema graph (Filter and
Sort are in the bar above the records);
workspace actions are in the ellipsis Menu and full sync/location details in the
read-only status sheet. One `SyncPill` (Mac sidebar bottom, iPhone bottom-bar status
slot, Mac menu bar) is the only sync surface: Synced, Syncing (only while rows move, edits upload
or before a first success), N pending, Offline · N pending, N rejected (opens
Issues), Paused: cap reached (hub 429), Sync issue, Shared with CLI or Local only.
Sync failures reach the pill and status sheet, never `model.error`. Ordinary saves
show no progress text. `SyncStatusUITests` drives `navigation-hub.py`'s
accept/reject/offline modes through those states and retains screenshots.
Cmd+\ (`WorkspaceCommands`, View > Toggle Sidebar) toggles the sidebar column,
persisted as `lifeui.sidebarHidden`; compact iPhone switches sidebar and detail.
The Mac status item (`WorkspaceMenuBar`, opt-out in Settings) mirrors the most
recently active window: Open, Quick Find, five recents and pinned tables by title
only. Its commands reach that window through the guarded navigation paths.
MenuBarExtra writes `isInserted` back on every scene update; bind it through a
setter that ignores unchanged values, and publish focused values that compare
equal across renders, or the Mac main menu rebuilds forever at launch.
Keep active errors and incomplete-table notices visible. Do not
reintroduce a permanent multiline sync footer. The graph sheet shares the offline
WebKit coordinator and bundled FK/group component with macOS; dismiss first,
then re-resolve the selected table through guarded navigation. `NativeControlsUITests`
checks menu/status/graph navigation and accessibility text sizing with screenshots.
`HeaderUITests` checks their geometry and retains screenshots. Its empty-workspace
case uses `HeaderUIFixtureTests` with `TEST_RUNNER_LIFE_UI_TEST_HEADER_SIMULATOR`
set to the exact disposable simulator UDID; run the fixture before the UI tests.
`TableNavigationUIFixtureTests` seeds 50,000 synthetic provenance rows on the
explicit `TEST_RUNNER_LIFE_UI_TEST_TABLE_NAV_SIMULATOR` only. Its local mode tests
repeated table navigation; the optional loopback `navigation-hub.py` mode holds
real sync HTTP while `TableNavigationUITests` verifies cached navigation and
persisted local saves before the response is released.

NativeWorkspace serializes whole database operations across every open instance
of the same file, yielding ownership only
at transaction-free HTTP boundaries. Suspended requests capture their transport;
responses reenter behind complete foreground operations. Close cancels their
transport and waits at most its grace for them to unwind, while duplicate sync
requests do not block local requests ahead of close. The sync file lock lasts through suspension. Progress carries phase,
table, page, row count and start time only. Cancel unwinds transport without
resetting checkpoints or discarding local changes. Synchronous JSC callback failures
reject only their captured request; roll back an unfinished transaction before
releasing file admission. The total deadline is fifteen
minutes, with per-request transport timeouts retained. Core commits each finished
table and resumes an interrupted table at its last applied page, so a round cut
short by the deadline or one failed request continues where it stopped.

Web design tokens live in `apps/web/src/theme.css`; use Tabler UI icons,
accessible controls, keyboard focus and narrow-screen layouts. Native views use
SwiftUI semantic styles. The graph initially fits the viewport; zoom keeps the
same offline SVG and table navigation, with one step reaching readable size.
Native graph changes must regenerate the bundled island.
`islands.css` explicitly scopes Tailwind sources to the embedded components;
unrelated web files must not change native artifacts. Verify this with
`bun scripts/test-island-builds.ts` before publishing regenerated resources.

## Shared local Mac workspace

An explicitly opened database is remembered in a private security-scoped bookmark.
Reopening a missing selection fails visibly rather than creating a replacement or
falling back to a different replica. The supported Life CLI file contract shares
SQLite data/schema and its existing write validation; the CLI background service
owns hub sync in this mode, with its own credential. The observer connection
reads only `_sync_state.hub_url` to show Shared with CLI; the app never syncs it. No consumer credentials are
shared. App hub mode remains an independent replica and clears the local choice.
A separate canonical-path read connection observes PRAGMA data_version while the
window is active. External commits refresh catalog/rows without resetting editor
drafts; optimistic saved revisions still reject conflicting commits. Cancel old
observation on workspace/scene changes. Never poll inside a core transaction or
alter generated core code to implement host observation.

## Nix distribution

`nix/package.nix` preserves the published signed archive without fixup or stripping.
`nix/darwin.nix` exports generic enable/package/migrateFromHomebrew options; early
checks precede application publication and the exact non-zap cask removal precedes
Homebrew cleanup. Keep the cask publisher available for Homebrew consumers.
Migration receipts and runtime data never belong in source.

Catalog editing uses canonical `saveCatalogProperty` and `saveCatalogRule` requests
with the displayed metadata revision. Both record an atomic `catalog_log` entry;
new properties also log nullable physical column DDL. Preserve existing record
values, select-option descriptions and ordering metadata. Failed edits retain the
form. Only explicitly app-owned local/demo setup provisions the canonical audit
manifest; imported replicas receive operator-provisioned logged schema through
sync. Schema changes invalidate old coverage, and enforced record rules remain
fail-closed until the ordinary sync establishes their validation dependencies.
