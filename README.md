# Life UI

A local-first Svelte web client and native SwiftUI apps for catalogued
life-data databases. The three clients consume the same TypeScript validation,
query, write and sync implementation. No PWA or analytics.

## Using the web workspace

Open the app, then choose **Open my workspace** or **Try sample workspace**.
The sample has its own persistent database and cannot sync to an account.
Your workspace accepts a hub URL and app-issued device token. The token stays
in memory for that browser session; stored rows remain available without it.
The hub must allow the web app's origin through CORS.

- Browse catalog tables, search and sort records. Added filters combine with AND;
  remove individual filter chips or clear them together.
- **Find records** (Cmd+K or Ctrl+K) searches records and offers tables and saved
  views in one keyboard list. Unavailable views explain why they cannot open.
- **Columns** chooses, reorders and sizes the displayed properties. Record stays
  visible first, and hidden properties remain available when editing the record.
- Create/edit typed fields, search related records by their display names,
  write Markdown with rich formatting or source editing, and move records to trash or restore them.
- Open a selected related record with its arrow button. Opening reads its current
  full row and prompts before discarding a draft. Multi-reference Remove buttons
  are separate; missing or trashed targets leave the current editor intact.
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
rejects a save if its references are missing from the local replica.
Selected references have a separate **Open** action, including on read-only
records. Opening reads the complete current local row. Missing targets keep the
source editor open with an explanation; skipped tables can still contain local
records. Unsaved changes require **Discard changes and open** or **Keep editing**,
and unrelated recovery drafts remain available.
Catalog rules, read-only tables, validation, history and stale-revision checks
come from shared core. An editor also captures its workspace and table, so
changing connections cannot redirect a save. Unsaved drafts require explicit
discard.
Editing controls use core's current table advisory and show why editing is
unavailable. The advisory refreshes after successful or failed sync; incomplete
invariant coverage leaves records browsable. Saved-view writes check the views
table separately. Every actual write rechecks its conditions transactionally.

**Find** searches across locally stored tables using the shared FTS5 index;
on macOS, press **Cmd+K**. Results show record names, table names and matching
snippets, with 50 results per request. Opening a match reads the full current
row and respects read-only tables. Find is unavailable while a record editor
is open, so it cannot replace an unsaved draft. **Search this table** remains
available for the current table. Skipped sync tables can make results incomplete.

**Views** opens saved views for the current table. Apply a view, save the current
settings as a new view, update its name or settings, or delete it without deleting
records. Imported column order appears in the record list; multi-column sorting
and grid widths are preserved when saving. Native sort controls edit the primary
sort while retaining later sort rules. Editors always read complete records,
including fields hidden by a view. Updating or deleting an applied view uses the
revision opened by the user; refreshing the list cannot silently adopt another
client's changes. Reopen a changed view before updating it.

Markdown fields open a dedicated screen containing the same **Write** and
**Source** editor as web, bundled locally in WebKit. Existing records autosave
editable Markdown after a 600 ms typing pause. **Done** collects the live document
and awaits the local write. Other property changes and new records still require
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
**Done** keeps the draft without saving it. Undoing a creation can put the record
in trash; use **Restore record**, then review and save the retained draft separately.
The live Markdown snapshot must be safely journaled before Undo can run.
An interrupted Undo with no confirmed result keeps the draft for the same
copy-and-review recovery flow described below; Undo receipts are never persisted.

Drafts are kept as private, atomic files in Application Support, isolated by the
database location, record and editor. App-owned databases use paths relative to
their app state so container relocation during an update preserves recovery;
external databases use canonical absolute paths. Separate windows keep separate
recovery drafts, including new records. **Resume draft** restores unsaved fields
after relaunch; **Discard draft** removes them explicitly. A stale recovered
revision cannot overwrite a newer row. An interrupted write with no confirmed
receipt retains its latest draft and requires review before saving again.
Use **Copy Markdown** or a field's **Copy** button, then **Keep draft and close**
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
session response. Cached records appear before sync finishes. **Sync now** sends
and receives updates; failures keep local records and edits available. Durable
pending/rejected counts and the last successful sync remain visible while
scrolling, with rejection details in the record list. **Forget saved connection**
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
Done collects a live snapshot to include the final keystroke. The island has
no database or credential bridge and blocks network access. The web client
autosaves Markdown on existing records after a short typing pause, with a visible
saving/saved state. Unrelated property drafts wait for **Save record**; new records
also require their first explicit save. Conflicts retain the draft. Native editors
also autosave existing Markdown bodies and flush on Done; property edits and new
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
Full grid keyboard editing and Notes migration remain open work.

Native references use named pickers and local record links; multi-select and JSON fields use source
editors. Native browse supports saved views, search, sort, combined filters,
trash and pages of 100 rows. Column widths are retained for the web grid;
native does not provide a grid-width or secondary-sort editor. Rejected edits retain
their data and show errors; a dedicated repair workflow remains open. Sync
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
- Ad Hoc distribution needs the distribution certificate and profile, then
  `IOS_PROFILE` and the iOS `deploy` recipe. Signed macOS distribution needs
  Developer ID, notarization, release CI and declarative installation.

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
