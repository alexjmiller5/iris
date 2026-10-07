# Life UI

A local-first Svelte web client and native SwiftUI apps for catalogued
life-data databases. The three clients consume the same TypeScript validation,
query, write and sync implementation. No PWA or analytics.

Markdown documents display retained PNG, JPEG, GIF, WebP, AVIF and BMP images
through the connected hub. Other retained attachments have an explicit download
action on the web and a native Quick Look preview. Image previews accept files up
to 8 MiB and display a static thumbnail; original downloads allow 128 MiB.
Missing files can be retried. Viewing preserves the original Markdown, and remote
images do not load automatically. Imported Notion links can open their local
record when a whole-record import mapping exists; the original link stays available.

## Using the web workspace

Open the app, then choose **Open my workspace** or **Try sample workspace**.
The sample has its own persistent database and cannot sync to an account.
In **Connect to a hub**, enter its address and choose **Approve this browser**.
Open the approval page, compare the displayed code, and approve through the hub's
owner sign-in. Return to Life UI while it waits for approval. The browser creates
its own device token; only its SHA-256 fingerprint appears in the approval link.
The token stays in memory for that browser session. The hub must allow this web
app's origin through CORS, including its existing session endpoint.

**Use a device token** is an explicit alternative: paste a dedicated full device
token, then choose **Sync now**. New credentials are validated before replacing
the current connection; root/admin and restricted tokens cannot open replicas.
A hub cap still permits enrollment and usage/notification access. Download limits
remain separate from enrollment.

Approval waits up to five minutes. Cancel, a different address, workspace changes
or a replacement attempt stop it and invalidate late responses. Cancellation
attempts to revoke only the newly generated candidate. An unauthorized cleanup
response does not prove cancellation: approval links do not expire at the hub,
so revoke an abandoned device through the hub if it is approved later.

While waiting, the browser retries transient network failures at the shared
policy interval within the original deadline. Malformed replies fail the attempt.
The core classifies replies; the browser explicitly owns these bounded retries.

Closing or switching workspaces forgets the in-memory credential and preserves
local rows for offline use. Forgetting is not revocation. Revoke an established
device through the hub's device management page. A replacement browser/device
creates a fresh credential through the same approval flow; no token export or
storage transfer is required.

- Browse catalog tables, search and sort records. Added filters combine with AND;
  remove individual filter chips or clear them together.
- **Find records** (Cmd+K or Ctrl+K) searches records and offers tables and saved
  views in one keyboard list. Unavailable views explain why they cannot open.
- **Columns** chooses, reorders and sizes the displayed properties. Record stays
  visible first, and hidden properties remain available when editing the record.
- Create/edit typed fields, search related records by their display names,
  write Markdown with rich formatting or source editing, and move records to trash or restore them.
- Website, email and phone fields offer explicit open actions. Websites open in
  a separate tab; the draft stays in the editor. Open actions also work when a
  property's editing control is disabled.
- Open a selected related record with its arrow button. Opening reads its current
  full row and prompts before discarding a draft. Multi-reference Remove buttons
  are separate; missing or trashed targets leave the current editor intact.
- **Referenced by** on a saved record groups incoming links by table and field.
  Open a group to load local records, page through more, or follow a named record.
  Skipped tables show a completeness warning; refresh updates the visible groups.
- Required fields, immutable/derived properties, reference validation and
  stale-edit checks use the shared core. Unsaved drafts prompt before leaving.
- View table relationships and group tables locally. Groups are separate for
  the sample and account workspace. The same graph component supplies the
  native graph island.
- SQLite persists through OPFS in a dedicated Worker. Web Locks serialize
  database operations across tabs; BroadcastChannel refreshes open views.
  Storage errors are reported instead of pretending an edit was saved.

The app edits any catalogued table; it does not infer a catalog for arbitrary
SQLite files or connect directly to other database engines. System tables
are read-only. Catalog entries with `kind: system` also remain read-only.

Table rules are checked locally before an edit commits. Invalid edits keep the
draft and leave stored records, history and pending edits unchanged. Rule-checked
tables need complete local copies of the tables used by their checks. Unrelated
large tables can stay excluded. Skipping a required table or interrupting sync
pauses editing; the app explains which tables to include and sync. This check
does not guarantee the hub has stayed unchanged: it checks edits again during sync.
A sync can receive records or acknowledge edits before a later request fails.
Open browser tabs refresh that progress and retain unsaved drafts.

**Browse online** opens an excluded table in a read-only window. Load 50 records
at a time, refresh from the beginning, or find an exact record ID. Opening a
result fetches its current complete row, including Markdown; records in the
trash are identified. These results stay in memory until the window closes.
Local rows, pending edits, search and editing availability remain unchanged.
The hub may change between pages, so the loaded count is not a snapshot or total.
Connect and sync the catalog before browsing online; usage caps and connection
failures remain visible and require an explicit retry.

**Saved views** keep a table's filters, search, sort, column order and widths in
ordinary synced `views` rows. Choose a view, **Save as** a new name, or use
**Update selected** to save changes and rename it. **Delete view** keeps the
records and returns to All records. Updates use the revision you opened, so a
remote change asks you to reopen and review instead of overwriting it. Invalid
or newer definitions stay visible with their reason and are preserved.

The sample workspace creates the standard storage locally. Connected workspaces
receive it through schema sync from their operator; the client never adopts an
unrelated table named `views`. Column visibility changes the grid only, so
editing still reads all of a record's fields.

**Copy link** shares the current table, saved view and saved record. Links use
`/workspace?table=<table-id>&view=<view-id>&row=<record-id>` with optional view
and row identifiers. Renaming a saved view does not change its link. Open the
matching workspace on the receiving device, and sync if the target is not yet
available there. Links never select a hub, open a workspace automatically or
carry credentials or record contents.

Back and Forward restore the destination from current local data, including
hidden editor fields and explicitly linked trashed records. Cancelling a draft
discard retains both the editor and its current address; pending writes block
navigation until their receipt. Missing destinations show an explanation while
keeping the current editor. Copy link includes the saved view's identity, so
reopening uses its latest saved definition. Unsaved filters, search, sort,
column changes, grid pagination and drafts are not encoded in links.

**Find records** (Cmd+K or Ctrl+K) searches across locally available tables,
including Markdown bodies. Results show the record title, table and an excerpt;
use the arrow keys and Enter to open one. Search matches word prefixes, ignores
accents, and requires every word in the query. Table search uses the same FTS5
index. External edits and sync pulls update the persistent index before searching.
Trashed rows stay out of quick find. A warning identifies potentially incomplete
results when tables are excluded from sync.

## Native apps

The macOS and iOS apps share `packages/LifeKit`: a SwiftUI catalog workspace
using the same TypeScript core through JavaScriptCore and GRDB. Browse/search
records, sort by a catalog field, combine filters, create/edit fields, edit
Markdown, and trash/restore rows. Sort and filter controls reset when
changing tables or workspaces. Reference fields offer searchable record names;
single and multiple choices save their underlying IDs through shared core.
Unavailable selections remain in the draft until explicitly removed. Core
rejects a save that carries references missing from the local replica. Like the
hub, an edit is judged only on the cells it carries, so stored values in other
fields (including deprecated ones) do not block it.
Selected references have a separate **Open** action, including on read-only
records. Opening reads the complete current local row. Missing targets keep the
source editor open with an explanation; skipped tables can still contain local
records. Unsaved changes require **Discard changes and open** or **Keep editing**,
and unrelated recovery drafts remain available.

**Incoming references** groups stored records that link to the open record by
source table and field. Expand a group to load 20 records, then choose **Load
more records** for the next page. Opening a result uses the same fresh-row and
unsaved-draft checks as other reference links. Read-only records remain
navigable. Skipped-table coverage is shown explicitly, including after reopening
offline; an empty local group does not imply that the hub has no matching rows.
Scrolling and opening Markdown preserve the surrounding record draft.

Catalog rules, read-only tables, validation, history and stale-revision checks
come from shared core. An editor also captures its workspace and table, so
changing connections cannot redirect a save. Unsaved drafts require explicit
discard.

The sidebar lists device-local recent destinations and a collapsible System
tables section ([native recents](docs/native-recents.md)). **Find** (Cmd+K on the
Mac) searches tables, saved views and records; each choice is re-read before it
opens. **Copy link** in the records header copies a `life://` link to the table
and applied saved view; the record editor copies a link to the saved record.
Received links wait in a banner until **Open link** is chosen in the matching
workspace, and never open a workspace, switch connections or replace an open
editor ([link contract](docs/native-deep-links.md)). **Duplicate record** copies
the current saved row into a new unsaved draft; nothing is written until Save.
New records show each field's catalog default; **Leave empty** saves an empty
value instead of that default.
Select fields show catalog choices and their descriptions. Multi-select fields
show removable choices and an **Add choice** menu. Choices supplied by a catalog
query load from the open workspace and can be retried after an error. Unknown
stored choices stay selected until explicitly removed; core still validates Save.
**Edit JSON source** keeps malformed multi-select values available for repair.
Opening a control does not rewrite its stored source.

Dates use a native picker. **Date source** holds the original text and **Clear
date** for an explicit unset value. Datetimes display in UTC; untouched milliseconds remain
intact. An invalid date stays visible until edited or explicitly replaced.
Boolean fields distinguish **Not set**, **True** and **False**. Website, email
and phone fields offer explicit system open actions for supported addresses.
Editing controls use core's current table advisory and show why editing is
unavailable. The advisory refreshes after successful or failed sync; incomplete
invariant coverage leaves records browsable. Saved-view writes check the views
table separately. Every actual write rechecks its conditions transactionally.

**Quick Find** offers tables and saved views before typing; on macOS, press
**Cmd+K**. Type to filter destinations and search locally stored records through
the shared FTS5 index. Use Up/Down to choose a result, then tap it or use the
keyboard’s Go action on iOS. Unavailable views
retain their reason, and metadata failures can be retried separately from record
search. Record matches show names, table names and matching snippets, with 50
records per request. Opening a destination reads its current view or full row,
including trashed rows, and respects read-only tables. Find is unavailable while
a record editor is open, so it cannot replace an unsaved draft. **Search this
table** remains available for the current table. Skipped sync tables can make
results incomplete.

**Views** opens saved views for the current table. Apply a view, save the current
settings as a new view, update its name or settings, or delete it without deleting
records. Imported column order appears in the record list; multi-column sorting
and grid widths are preserved when saving. Native sort controls edit the primary
sort while retaining later sort rules. Editors always read complete records,
including fields hidden by a view. Updating or deleting an applied view uses the
revision opened by the user; refreshing the list cannot silently adopt another
client's changes. Reopen a changed view before updating it.

In **Views > Properties**, choose which properties appear and drag to reorder
them. **Title only** keeps the record's title prominent. Apply the layout, then
save or update a view to keep it across devices. Hidden values remain available
under **More properties** in the record editor; required new fields and invalid
values remain visible. **Record details** holds IDs and timestamps, and the
small **Catalog rules** link at the bottom opens the table's rules separately.
Empty existing properties collapse into **Empty properties**; zero and false
stay visible. A property stays in its disclosure while being edited, and failed
validation reveals the affected property. Required new fields stay visible.

On iPhone, tap a property in the table list to edit it there, then **Save**.
The expand icon opens the full record pop-up; **Open record** in an inline editor
transfers the same unsaved draft. Both presentations use the same local save,
validation and recovery journal. Close or save an inline editor before changing
tables, filters, views or connections. Background sync continues while editing.
Markdown cells show a bounded, formatted preview. Editing expands only the active
cell into the rich editor; other properties keep their compact presentation.
The prepared draft retains its live editor across background refreshes and table
scrolling. Save, Cancel and Open record collect the final text before acting.
The full record places visible Markdown bodies beneath the compact properties,
ready to write without opening another page. Empty bodies stay available;
explicitly hidden bodies remain under More properties.

Image filename URLs, retained file paths and JSON arrays of image references
show previews. Bounded raster and SVG data URLs are supported too. **Image source**
keeps the original value editable. Retained files use the current hub connection;
public HTTPS images never receive its credential. Redirects are refused, and SVG
previews cannot execute scripts or load network resources. Unrecognized or
extensionless references retain their text presentation.

Markdown uses the same editor as web, bundled locally in WebKit. Type `# ` or
`## ` for headings, `- ` for bullets, or `/` on an empty line for block choices.
Formatting actions appear when text is selected; the options menu contains
Source, Undo and Redo. Existing records autosave
editable Markdown after a 600 ms typing pause. **Save** collects every live body
and awaits the local write; closing or opening a related record also collects
the final input before checking for unsaved changes. Other property changes and new records still require
**Save**. Later typing stays in the draft while a write is pending, and successful
receipts advance the editor's revision without replacing those changes. A failed
identical edit waits for a change or explicit retry. The status says **Saved on
this device** only after the write succeeds; hub synchronization is separate.

**Undo last saved change** reverses the last successful record write in the open
workspace, including creation, edits, trash and restore. Each Markdown autosave
is a separate saved change. Undo revalidates the inverse and creates fresh history;
it does not restore old timestamps. Success consumes the action, with no redo,
and closing the workspace forgets it. Text-editor undo remains separate.
An open editor's newer draft stays intact, including when Undo affects another
record. Its autosave pauses
until an explicit **Save**, also after a failed Undo. While paused, Markdown
**Keep draft and close** keeps the draft without saving it. Undoing a creation can put the record
in trash; use **Restore record**, then review and save the retained draft separately.
The live Markdown snapshot must be safely journaled before Undo can run.
An interrupted Undo with no confirmed result keeps the draft for the same
copy-and-review recovery flow described below; Undo receipts are never persisted.

Drafts are kept as private, atomic files in Application Support, isolated by the
database location, record and editor. App-owned databases use paths relative to
their app state so container relocation during an update preserves recovery;
external databases use canonical absolute paths. Separate windows keep separate
recovery drafts, including new records. Windows using the same database coordinate
complete local operations, so one window opening or saving cannot interrupt
another window’s transaction. Network waits release this local coordination.
Open regular files or symbolic links; hard-linked databases are refused because
SQLite journals cannot safely follow multiple filenames. **Resume draft** restores unsaved fields
after relaunch; **Discard draft** removes them explicitly. Recovery stays attached
to the exact stored record, even when two record IDs look identical. A stale recovered
revision cannot overwrite a newer row. An interrupted write with no confirmed
receipt retains its latest draft and requires review before saving again.
Use a field's **Copy** button, then **Keep draft and close**
to leave without saving or deleting the recovery draft. The Markdown actions
collect the live editor source before copying or closing. Reopen the row and choose
**Open saved record** to inspect its latest values and paste reviewed changes
into a fresh editor. The old recovery draft remains until explicitly discarded.
Backgrounding collects a nonlocking live snapshot and attempts to finish saving
within the available background time.
Recovery covers changes received and journaled by the native host; a forced kill
before WebKit delivers a change can still lose that keystroke. New-record drafts
remain recoverable without automatically creating a row. The temporary sample
workspace does not retain recovery drafts across launches.

Opening a document preserves its original source. Each editor session has a new
document identity, so callbacks from closed or replaced documents cannot change
the current draft. If the embedded editor fails, a native source editor keeps the
last received draft available. The island has no network, database or credential
access.

Choose **Open local workspace** for persistent local notes with sample topics, or
**Try sample workspace** for an in-memory preview. macOS also opens existing
catalogued SQLite files for local use. It never automatically opens the CLI's
database or syncs a file selected through that picker.
App-owned local workspaces initialize missing shared saved-view storage;
external files, replicas and existing name collisions are not altered by that
initialization. Unavailable saved views show their reason and remain untouched.

**Connect to hub** accepts an HTTPS endpoint. Enter a device name, choose
**Request approval**, then **Open approval link** to approve it in your hub.
Match the displayed approval code. The link contains a fingerprint, never the
device credential. Approval polling uses the hub's shared policy and expires
locally; **Cancel approval** stops installation and attempts to revoke only that
candidate. An unapproved link can still be approved later, so unconfirmed cleanup
explains how to revoke it in the hub. Closing the app while waiting cannot promise
revocation. Replacement devices follow this same flow with a fresh credential.

**Use existing token** is an alternative for a dedicated full-scope device token.
New credentials must pass the hub session and replica checks before replacing
Keychain or the current workspace. Operator/admin and restricted tokens are
rejected. Failed validation or Keychain storage leaves the old connection intact.
The credential stays in this device's Keychain and is never copied to another
device. Loopback HTTP is supported for development.

An established Keychain-backed replica reopens offline without requiring a fresh
session response. Cached records and local saves remain available while network
sync runs. While the app is open, saved edits sync automatically after a short
pause, with periodic catch-up every minute. Failed or cancelled rounds wait a
minute before automatic retry; **Sync now** retries immediately. The status button
opens progress, elapsed time, Cancel, pending/rejected counts and the last
successful sync. Failures keep local records, edits and drafts available.
Open **Issues** to page through durable rejected edits, including after
reopening offline. **Review edit** opens the current local record with the rejected
editable values held in a paused draft. Save a correction, then sync; only an
accepted sync removes the inbox entry. Trashed records require Restore first,
which keeps the review draft. A failed or cancelled review keeps existing drafts
and navigation intact. **Forget saved connection**
removes the local Keychain entry and keeps the replica; it does not revoke the
device at the hub. Use the hub's device controls to revoke access separately.

**Downloads** in connection settings controls the automatic row limit and each
table's **Automatic**, **Include** or **Skip** choice. Leave the limit blank to use
the shared default. Catalog tables always download. Choices are private to this
device and hub, survive reconnecting, and apply on the next sync. Skipping keeps
existing local rows; an incomplete table offers **Include in next sync**.
Incomplete-table warnings survive reopening offline and also apply to Find
and reference links.

**Browse online** opens the current hub table in a separate read-only sheet,
50 records at a time. Opening a result fetches its current full row; missing and
deleted records are explicit. Enter a **Record ID** and choose **Find ID** to
open an exact match without loading earlier pages. Markdown uses the same local
viewer with editing disabled. Online rows stay in memory and never populate local records, search,
pending edits or sync coverage. Close the sheet to clear them. Online browsing
is unavailable while a local record editor is open, preserving its draft.
Connection and usage-cap errors remain visible for an explicit retry.

**Usage** in connection settings shows this deployment's current period and
reset, four metrics with separate free allowances and hard caps, and principal
totals excluding storage. Missing measurements say **Unmeasured**. Usage loads
when its screen opens or **Refresh** is selected, including after a failed sync.

**Notifications** shows the generic hub feed and unread count. Marking one or
all read updates shared deployment state. The feed refreshes every minute while
the app is active; leaving the foreground or changing connections cancels that
poll. **Enable alerts** explicitly requests notification permission. First
contact establishes a quiet baseline, and successful event IDs are retained
per endpoint so retries do not repeat alerts. Native foreground presentation
uses banners, list entries and sound. APNs/background delivery is not implemented.
Actual OS banner delivery still requires an installed app, owner permission and
verification on an unlocked device; automated tests use an injected presenter
and never request notification authorization.

Application Support contains `life-ui/local.sqlite`, per-endpoint databases
under `life-ui/replicas/`, per-hub download preferences under
`life-ui/replicas/downloads/`, per-workspace graph groups, and alert preferences,
baselines and delivered event IDs under `life-ui/alerts/`. Credentials never
appear in these files. The facade serializes whole asynchronous core requests;
sync holds the Python-compatible `<database>.sync.lock`. URLSession rejects
redirects and omits cookies and cached credentials. macOS embeds the same
self-contained graph component as web in a WKWebView, with table navigation
and local grouping. The graph has no network access or SQL/credential bridge.

Native tests use synthetic temporary databases and a synthetic URLSession hub.
For the real Worker fixture described below, run:

```sh
LIFE_UI_TEST_HUB=http://127.0.0.1:5200 swift test \
  --package-path packages/LifeKit --scratch-path "$HOME/Library/Developer/life-ui-swift"
```

This opt-in test pulls schema/catalog over HTTP, writes offline, reopens the
database, and verifies accepted edits at the hub. Set
`LIFE_UI_TEST_SERVICES_HUB` to the `scripts/services-hub.ts` fixture URL for
real HTTP Usage and complete-feed tests. Xcode tests accept these variables
with the `TEST_RUNNER_` prefix; the services UI test requires a fresh fixture
with its 205 unread synthetic events and verifies individual and shared
mark-all-read actions. To include interrupted-save UI recovery, set
`TEST_RUNNER_LIFE_UI_TEST_RECOVERY_SIMULATOR` to the selected disposable simulator's
UDID. The app-host test seeds only that simulator's local workspace before the
UI test copies recovered text, exits, opens the saved row and relaunches.

For the native navigation regression, use a disposable simulator: the fixture
replaces its saved connection and seeds 50,000 synthetic provenance rows. Start
`uv run scripts/navigation-hub.py --port 0` and use its printed loopback URL:

```bash
TEST_RUNNER_LIFE_UI_TEST_TABLE_NAV_SIMULATOR="$SIMULATOR_UDID" \
TEST_RUNNER_LIFE_UI_TEST_TABLE_NAV_HUB="$FIXTURE_URL" \
xcodebuild -project apps/ios/LifeUI.xcodeproj -scheme LifeUI \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- test \
  -only-testing:LifeUITests/TableNavigationUIFixtureTests \
  -only-testing:LifeUIUITests/TableNavigationUITests
```

This holds a real sync response while opening a large cached table, returning to
notes, saving an edit and reopening the stored record. Run again without
`TEST_RUNNER_LIFE_UI_TEST_TABLE_NAV_HUB` for repeated
local large-table navigation. Each mode skips the other mode's tests. Retained
XCTest screenshots show the saved record while sync remains held. Stop the fixture server
when finished. Local navigation and inline saves run while sync awaits HTTP;
database transactions still retain complete ownership until they finish.

`LargeMarkdownNavigationUIFixtureTests` and `LargeMarkdownNavigationUITests`
exercise a 454-record synthetic Markdown table, scrolling and table changes.
Use `TEST_RUNNER_LIFE_UI_TEST_MARKDOWN_NAV_SIMULATOR` for its exact disposable
simulator, and set `TEST_RUNNER_LIFE_UI_TEST_MARKDOWN_NAV_CATALOG=1` for the
85-table catalog with populated relation and JSON properties. The optional
`TEST_RUNNER_LIFE_UI_TEST_MARKDOWN_NAV_HUB` uses the same loopback fixture to
hold sync HTTP. Seed the app-host fixture before running the UI test. Measurements
include XCTest polling and interaction overhead, and do not replace phone acceptance.

`NativeReadCancellationTests` and `WorkspaceReadCancellationTests` check
queued-read cancellation, preserved visible state and reconciliation after committed
edits. Passive reference labels yield to queued local foreground work without
interrupting an active database operation or crossing transport/close barriers.
Only one passive label read per workspace enters the database queue at a time;
the remaining callers wait outside it and can cancel before admission. This keeps
a queued service request from trapping navigation behind the entire label backlog.
`LIFE_UI_REFERENCE_BARRIER=1` enables the real-core synthetic catalog measurement
with 300 labels followed by a service request and table navigation in
`ReferenceAdmissionPerformanceTests.measureNavigationWithQueuedServiceBarrier`.
For an opt-in synthetic measurement with a large catalog and 70, 100 or 300
pending reference labels, run in an otherwise idle build window:

```sh
LIFE_UI_REFERENCE_ADMISSION=1 swift test --package-path packages/LifeKit \
  --scratch-path "$HOME/Library/Developer/life-ui-swift" \
  --filter ReferenceAdmissionPerformanceTests
```

The harness records destination resolution, visible row publication and local
save completion separately. It uses an in-memory fixture and measures native
model/core work; it does not establish phone frame timing or touch responsiveness.

Launch an Apple app with
`--demo` for the temporary preview; app-hosted tests use fixture mode as well.
Unsigned builds are development artifacts, not signed releases or phone installs.

## Run and verify

Requirements: Bun 1.4.2, just, and for Apple targets Xcode with Swift 6,
XcodeGen and an installed iOS simulator. Install tools through your declared
environment. Development fixtures require no credentials.

```sh
bun install --frozen-lockfile
just dev
just test
just check
just build

just --justfile apps/macos/justfile run
just --justfile apps/macos/justfile test
just --justfile apps/ios/justfile run
just --justfile apps/ios/justfile test
```

`just test` runs web, test-runner safety and Swift package tests. `just check` checks web types and
formatting and compiles both native targets without an Apple account.
`just build` builds the Worker, unsigned macOS Release app and iOS simulator
app. CI verifies sources without deploying. Child `project.yml` files are
canonical; `just gen` regenerates the ignored Xcode projects.

`IOS_TEST_DESTINATION` selects another installed simulator.
`IOS_DERIVED_DATA`, `MACOS_DERIVED_DATA` and `LIFE_UI_SWIFT_CACHE` override
cache paths, which default under `~/Library/Developer`.

Browser smoke tests attach to a dedicated, already-open Chrome CDP page:
The enrollment runner uses only `http://life-ui-enrollment.localhost:5230/workspace?review`
and disposable actual Worker auth state:

```sh
bun scripts/test-enrollment-host.ts /path/to/life-data
bun scripts/test-enrollment.ts /path/to/life-data
```

Run them sequentially: concurrent Playwright connections to one browser can
interfere with each other's confirmation dialogs. Keep source generators and
type checks idle during these tests to avoid development-server reloads.
Runners select their exact origin and `/workspace` through `workspacePage`,
independent of product navigation parameters. Ambiguous tabs are rejected.
Two-tab runners retain their observer handle and restore its fixture URL before
disconnecting; product links intentionally discard `review` and `observer` flags.

```sh
LIFE_UI_TEST_URL=http://127.0.0.1:5196/workspace bun scripts/test-workspace.ts

# Separate test origin keeps integration fixtures out of another workspace.
bun scripts/test-hub.ts /path/to/life-data
bun run dev -- --port 5197
# Open http://127.0.0.1:5197/workspace in the dedicated test browser page.
bun scripts/test-sync.ts

# Use dedicated disposable origins for rejection and concurrency checks.
LIFE_UI_TEST_HUB_PORT=5201 LIFE_UI_TEST_ORIGIN=http://localhost:5196 \
  bun scripts/test-hub.ts /path/to/life-data
# Open http://localhost:5196/workspace in another dedicated test page.
bun scripts/test-rejections.ts
# Durable inbox: 205 real hub rejections, bounded paging, corrupt-page retries,
# paused repair/Restore, accepted receipts, offline reopen and stale replies.
# Reserve http://life-ui-rejections.localhost:5238/workspace?review first.
bun scripts/test-rejection-inbox.ts <life-data-checkout>
# Open http://life-ui-write-fixes.localhost:5196/workspace?review in its own page.
bun scripts/test-workspace-regressions.ts /path/to/life-data
# Open http://life-ui-sql-integrity.localhost:5198/workspace?review in its own page.
bun scripts/test-sql-integrity.ts /path/to/life-data
# Open http://life-ui-markdown.localhost:5198/workspace?review in its own page.
bun scripts/test-search.ts
bun scripts/test-search-sync.ts /path/to/life-data
bun scripts/test-saved-views.ts /path/to/life-data
bun scripts/test-typed-filters.ts /path/to/life-data
bun scripts/test-table-invariants.ts /path/to/life-data
bun scripts/test-read-dependencies.ts /path/to/life-data
bun scripts/test-remote-browse.ts /path/to/life-data
# Also open /workspace?review&observer=1 on the same reserved origin for this test.
bun scripts/test-partial-sync.ts /path/to/life-data
# Open http://life-ui-relations.localhost:5223/workspace?review in its own page.
bun scripts/test-reference-navigation.ts /path/to/life-data
# Only while owning that checkout and its dev server: temporarily mutate the route.
bun scripts/test-reference-mutations.ts /path/to/life-data
# Open http://life-ui-navigation.localhost:5224/workspace?review in its own page.
bun scripts/test-workspace-navigation.ts /path/to/life-data
bun scripts/test-navigation-mutations.ts /path/to/life-data
```

The first test covers validation, Markdown persistence, relations, trash,
restore, filtering, draft protection, light/dark mobile layouts and graph
navigation. The second serves the actual hub Worker against synthetic SQLite,
then verifies an offline browser edit reaches the hub. Rejection checks cover
repair and retry; regression checks cover pending saves, SQL defaults, dynamic
options, workspace switching and durable pending counts. The regression runner
clears data only on a reserved `life-ui-*.localhost` test hostname from
`scripts/test-origin.ts`, with `/workspace?review`. Ordinary localhost and
remote origins are rejected before connecting to Chrome. SQL integrity checks reject
read-side writes before execution, preserve rows/history after invalid defaults,
and verify ordinary schema replay and sync. Environment overrides:
`LIFE_UI_TEST_CDP`, `LIFE_UI_TEST_URL`, `LIFE_UI_TEST_HUB`,
`LIFE_UI_TEST_HUB_PORT`, `LIFE_UI_TEST_ORIGIN`. Test hubs listen on loopback.

Reference navigation checks use real Worker/OPFS reads and a synthetic hub. They
cover fresh full-row lookup, cross-table IDs, draft cancellation, stale replies,
read-only references, missing/trashed targets, skipped tables, pending writes,
destination saved views and narrow layouts. `LIFE_UI_REFERENCE_CASE` selects a
case by name; `LIFE_UI_TEST_SCREENSHOTS` optionally names an output directory.

Dependency checks exercise the actual browser SQLite adapter against the shared
life-data fixture, including expanded views, engine contexts, unsupported
namespaces and preparation without executing validation queries. The invariant
flow also changes a rule's dependencies during sync and verifies that only its
required tables need complete replication.

Online browsing checks exercise real Worker/OPFS paging, fresh full-row lookup,
deleted and missing records, a held response across close/reopen, local draft
retention, usage caps, first-sync failure visibility and narrow layouts.

URL navigation checks cover table/view/row restoration, fresh full rows, encoded
identifiers, browser Back/Forward, draft cancellation, pending receipts, delayed
replies, missing destinations and clipboard contents. `LIFE_UI_NAVIGATION_CASE`
selects a case by name. Its held replies delay only delivery from the real
Worker; SQLite, OPFS and the synthetic hub remain active.

## Core and build ownership

life-data owns the source. Regenerate the committed browser and native
artifacts from one source checkout:

```sh
bun run bundle:core /path/to/life-core/src/validate.ts

# Rebuild the native adapter and web islands from this checkout alone.
bun run bundle:native
bun run bundle:graph
bun run bundle:editor
```

The full core bundles carry the same source SHA-256; validator-only artifacts
carry the validator's SHA-256. Generated bundles contain no developer paths.
A clean Life UI checkout builds without a sibling life-data checkout.
CI regenerates the native resources and rejects a stale committed artifact.
Never patch generated files by hand. `scripts/native-core.ts` is the native
adapter, not a second validator. No native SQL callbacks are exposed to web
content.

`apps/web`, `apps/macos`, `apps/ios`, `packages/LifeKit`, `packages/core` and
`scripts` follow the repository's platform boundaries. The independent
mockup remains in `../life-ui-mockup`.

## Markdown editing

Write mode supports headings, bold and italic text, links, lists, checkable
items, quotes, code blocks, tables, undo and redo. Type `/` on an empty line to
open the block menu. Source mode edits plain Markdown, which is the stored
format. Opening a document or switching modes preserves its original source;
an actual rich edit serializes it as Markdown. Unsupported HTML and imported
custom tags remain inert text, with Source available for exact editing.
Image references are retained as placeholders without loading remote images.

The native editor uses the same component in a single bundled HTML resource.
Its bridge accepts document state and emits changes with an opaque draft ID;
Save and close collect live snapshots to include the final keystroke. The island has
no database or credential bridge and blocks network access. The web client
autosaves Markdown on existing records after a short typing pause, with a visible
saving/saved state. Unrelated property drafts wait for **Save record**; new records
also require their first explicit save. Conflicts retain the draft. Native editors
also autosave existing Markdown bodies and collect them before Save; property edits and new
records require Save. Every save uses the shared validated write path.

Browser checks for the editor use a dedicated `life-ui-markdown.localhost`
review tab:

```sh
bun scripts/test-markdown-editor.ts
bun scripts/test-editor-island.ts
bun scripts/test-body-autosave.ts
```

## Current limits

This is an MVP implementation in progress. Supported table SQL invariants use
the shared core. Custom triggers, declared SQLite foreign keys and enforced
estate-wide rules remain read-only because their effects cannot yet be validated
and replayed consistently across clients. Catalog reference fields are supported.
External files with table invariants remain read-only without verified sync coverage.
Missing references must be included in the replica before editing them.
Online browsing is explicit and read-only. Native table search and
cross-table Find both use the shared local FTS5 index.
The web grid supports inline keyboard editing. On macOS 14 and later, double-click
a table cell to edit that property in place, or press Return to edit the selected
row's title. The open button and row context menu show the full record editor;
expanding an inline edit keeps its draft. Click a column heading for ascending or
descending sort or a filter for that property. iOS properties support inline
editing with an optional full record pop-up. Property information appears beside
its info button.
The web sidebar includes device-local recent destinations and a collapsible
System tables section. See [sidebar navigation](docs/sidebar-recents.md) for
storage and availability behavior. Native Find opens with Cmd+K on the Mac, and
Return activates the selected result with a hardware keyboard on either platform.

Native references use named pickers and local record links. Select and multi-select
fields show catalog choices; malformed selections and JSON fields retain source
editors. Native browse supports saved views, search, sort, combined filters,
trash and pages of 100 rows. The Mac table honors saved column order and widths;
resizing its columns is temporary. Native does not provide a saved grid-width or
secondary-sort editor. The Issues sheet
retains rejected values and supports local correction with an explicit Save. Sync
runs on connection and explicit request,
not in the background. Native device approval installs a dedicated credential
only after the hub session is validated; manual token entry is also available.
The graph is available on web and macOS; iOS graph presentation
is outside the MVP. Native property edits and new records require explicit Save;
existing-record Markdown autosaves locally. Recovered stale drafts retain their
source for review; automatic conflict merging is not implemented.

Browser OPFS availability is required, including for the local catalog and
binding used by online browsing. The app has no service worker or promise that
a closed web app can cold-load without a network connection. An already-open
workspace can edit its local data offline.

## Notifications and usage

Notifications come from the signed-in hub's generic feed. Usage alerts and
other producers share the same list. Reading an item or marking the list read
updates the hub's read state across devices. Web shows an unread badge and
refreshes while visible, on reconnection and on request. Requests are tied to
the explicitly connected endpoint; draft connection fields cannot redirect them.

Settings shows the hub deployment's current billing period, reset time and
measurement freshness. Reads, writes, requests and storage show the supplied
allowance and hard cap. Unmeasured values stay unmeasured. Device and service
rows show their read/write/request totals; storage remains a deployment-wide
gauge. Usage and notifications remain available when a cap pauses data sync.
No provider credentials or account-wide billing requests belong in a client.

Apple clients offer an explicit **Enable alerts** action. The initial feed is
history, not a burst of new system alerts. Presentation checkpoints and stable
notification IDs are local to each device and deployment. Foreground delivery
uses native notifications; APNs registration and background delivery remain a
separate hub-owned phase. System notification permission is a user choice.

The shared service contract lives in life-core. To test against synthetic state
using the hub implementations (the same checkout can supply both after merge):

```sh
bun scripts/services-hub.ts /path/to/life-data /path/to/usage-hub
# Open http://life-ui-services.localhost:5198/workspace?review in a dedicated page.
bun scripts/test-services.ts /path/to/life-data /path/to/usage-hub
```

The browser test starts its own hub with more than one page of notifications.
It verifies shared read state, usage, null storage, cap behavior, deployment
isolation and mobile layout. The persistent fixture defaults to port 5204 for
native testing. Both use synthetic records and loopback interfaces only.

## Owner setup

- `.env.tpl` is the Life UI CI bootstrap manifest. Run
  `op-project-bootstrap /path/to/life-ui/.env.tpl --repo <owner>/life-ui`
  for the deployment repository. Credentials must be minted for Life UI. Cloudflare
  Workers Scripts Write is account-scoped, so that broader deployment scope
  needs an explicit decision before provisioning the CI token.
- Provision Life UI's own Worker and Access application, then enable deployment.
  The supported data dependency is the life-data hub API with independent
  device credentials, never its backing database or infrastructure token.
- For iPhone development installation, enroll the device/team through Xcode,
  set `IOS_DEVELOPMENT_TEAM` and `IOS_DEVICE_ID`, then run the iOS `build`
  recipe. `IOS_INSTALL_HOST` can name the Mac paired to the device.
- Ad Hoc distribution uses the manual **Build iOS Ad Hoc** GitHub workflow.
  The existing project CI service account reads the Apple Distribution P12,
  password and Ad Hoc profile from the documented Apple Signing vault exception.
  Store `IOS_DEVICE_ID` in the project ENV item for the intended enrolled phone.
  The only GitHub secret remains `OP_SERVICE_ACCOUNT_TOKEN`.
  CI checks profile eligibility, signs in a temporary keychain and verifies the
  exported IPA before encrypting it. It does not install or start OTA.

Generate a temporary age identity outside the repository, keep it until download
and decryption finish, and pass only its public recipient to the dispatch:

```sh
umask 077
signing_dir=$(mktemp -d)
age-keygen -o "$signing_dir/identity.txt"
age-keygen -y "$signing_dir/identity.txt"
gh workflow run build-ios.yml --ref main -f artifact_recipient='<public-age-recipient>'
gh run watch <run-id> --exit-status
gh run download <run-id> -n LifeUI-iOS-<source-sha> -D '<private-output-directory>'
age --decrypt -i "$signing_dir/identity.txt" \
  -o '<private-output-directory>/LifeUI.ipa' '<private-output-directory>/LifeUI.ipa.age'
```

Keep the `signing_dir` location until the artifact is decrypted. On Nix hosts,
`nix shell nixpkgs#age` provides these commands without a permanent installation.
Only the encrypted IPA is uploaded, retained for one day. Public-repository
Actions artifacts can be downloaded by signed-in readers; they are not private.
The IPA must embed its provisioning profile, including registered device IDs, so
never upload plaintext IPA/profile files or signing keys. Keep the temporary age
identity locally, then delete it after successful decryption and verification.
After verifying the downloaded app signature, profile and checksum, install the
IPA on its enrolled phone or use `scripts/ota-install.sh <private-ipa-path>` through
the separately authorized installer. Each CI dispatch and retry gets a distinct
build number and versioned OTA page. **Workspace status > App version** shows the
installed version and build for acceptance checks. Install over the existing app
to retain its local workspace and pending edits. An archive/export success is not
proof of phone installation.

### Mac releases

The tag-only `Release macOS` workflow builds a universal Apple Silicon/Intel
application, signs it with Developer ID, notarizes and staples it, then publishes
`LifeUI-vX.Y.Z.zip` and `SHA256SUMS` in GitHub Releases. The version stamped into
the app comes from the stable `vX.Y.Z` tag. Branch pushes do not publish releases.

Before the first release, bootstrap the project CI account with the `.env.tpl`
manifest, including its documented access to the shared Apple Signing vault.
Set the GitHub repository variable `HOMEBREW_TAP_REPOSITORY` to the tap's
`owner/repository`. The shared tap credential must have write access there.
Set `MACOS_PROVISIONING_PROFILE_ID` to the App Store Connect API ID of this
app's Developer ID (`MAC_APP_DIRECT`) provisioning profile. The profile must
authorize the existing signing certificate and this app's bundle ID. Create or
renew that app-owned profile through Apple's developer tools; CI downloads it
with the existing App Store Connect team API key. That key needs profile read
access. CI neither creates certificates nor uses cloud signing.
The app itself never receives any of these credentials.

After release approval, push the chosen version tag and watch both workflow jobs.
Before notarization/publication, CI verifies the final app's private App ID and
team entitlements in both architectures against its embedded profile and exact
selected certificate. A separately signed probe uses the production credential
store to create, read, update and delete a unique synthetic item in the Data
Protection Keychain, including its device-only accessibility policy. These checks
require a logged-in macOS user context. A missing profile or failed storage test
stops publication; CI never falls back to the file-based Keychain.
Signing, storage verification, notarization, Gatekeeper verification and upload
must succeed before the cask is updated. If only the cask job fails, rerun that failed job; do not move the
published tag or replace its archive. Older retries and identical version/hash
pairs leave the tap unchanged. A different hash for the same version or unsupported
version/checksum format fails closed. Install through the configured, fully
qualified tap token, such as `owner/tap/life-ui`. In nix-darwin that token belongs
in `homebrew.casks`; rebuild the machine configuration. The installed app keeps
its workspace in Application Support and its device credential in Keychain.

Development and tests do not publish a release or cask. Release verification also
includes enrollment through the installed app after declarative installation.

No production data is migrated by development or tests.

The browser SQLite build is pinned and reproducible through Nix. See
[vendor/wa-sqlite](vendor/wa-sqlite/README.md) for regeneration and the real OPFS
FTS5 regression fixture. Normal app builds consume the committed JS/WASM pair.

Undo last saved change reverses the latest successful row create, edit, trash or
restore in the current workspace session. It uses the same rules and revision
checks as an ordinary edit. Newer unsaved drafts stay visible and body autosave
pauses until you review and save them. Undoing creation moves the record to Trash;
Restore makes its retained draft editable again. Reopening clears this action.
The Markdown editor's text Undo is separate.

Run the real OPFS Undo checks against a reserved fixture origin:

```sh
LIFE_UI_TEST_URL=http://life-ui-markdown.localhost:5198/workspace?review bun scripts/test-session-undo.ts /path/to/life-data
```

Saved views can combine individual filters with all/any rule groups, compare date
fields to Today in a chosen timezone and day boundary, and preserve multiple
ordered sorts. The default boundary is midnight; choosing 03:00 keeps early-morning
records in the previous task day. A missing clock time advances to the next valid
instant, and a repeated clock time uses its first occurrence.
Option order follows the catalog. View options also define labeled buttons with
literal property values and their position among visible columns. Save the view
before using its actions; local edits retain the normal undo and sync behavior.

The workflow browser regression uses a reserved disposable origin and synthetic
hub state: `LIFE_UI_TEST_URL=<reserved-url> bun scripts/test-workflow-views.ts <life-data-checkout>`.
It checks grouped conditions, configured day-boundary/foreground refresh, actions
and reopen. `scripts/test-view-options.ts` also covers policy persistence, typed
filter changes, live action choices and stale displayed-view rejection.
The native `WorkflowViewsUITests` uses `SavedViewsTests.prepareSavedViewsUIFixture`
on the exact disposable simulator selected by `LIFE_UI_TEST_SAVED_VIEWS_SIMULATOR`.

### Share a Mac database with the Life CLI

On the Mac, close the current workspace, choose **Open a local database…**, and
select the file printed by `life path`. Life UI remembers that file for the next
launch. Both clients now read and write the same SQLite database, including while
offline. Foreground windows observe committed changes every 250 ms; commits refresh
catalog and grid data without replacing unsaved editor drafts. A conflicting save
keeps the draft for review instead of silently overwriting the other writer.

The CLI's configured background sync owns hub synchronization for this shared
workspace. Life UI does not borrow its credential or run a second replica sync
against the file. Keep the CLI background service enabled for cross-device sync;
local UI/CLI visibility works without it or a network connection. The existing
hub connection mode remains an independent app replica for devices without a
shared file. Connecting a hub explicitly switches back to that mode.

Opening an existing database never seeds a sample, copies a replica over it, or
replaces a missing selected file. Existing replicas and recovery drafts are kept.
Before changing from a separate replica, finish its pending sync and preserve any
unsaved drafts; switching files does not merge separate local write queues.
