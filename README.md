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

- Browse catalog tables, search, sort and filter records.
- Create/edit typed fields, search related records by their display names,
  write Markdown source, and move records to trash or restore them.
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

## Native apps

The macOS and iOS apps share `packages/LifeKit`: a SwiftUI catalog workspace
using the same TypeScript core through JavaScriptCore and GRDB. Browse/search
records, create/edit fields, preserve Markdown source, and trash/restore rows.
Catalog rules, read-only tables, validation, history and stale-revision checks
come from shared core. An editor also captures its workspace and table, so
changing connections cannot redirect a save. Unsaved drafts require explicit
discard.

Choose **Open local workspace** for a persistent local notes workspace, or
**Try sample workspace** for an in-memory preview. macOS also opens existing
catalogued SQLite files for local use. It never automatically opens the CLI's
database or syncs a file selected through that picker.

**Connect to hub** accepts an HTTPS endpoint and an existing scoped client
token. Both are saved in this device's Keychain, without prompts during normal
use. Loopback HTTP is supported for development. **Save and sync** opens an
app-owned replica; **Sync now** sends and receives updates. Network failures
leave local edits available, and durable pending/rejected counts and the last
successful sync remain visible while scrolling. Rejection details stay in the
scrollable record list. Forgetting the saved connection removes its
Keychain entry and retains the replica for reconnecting to the same hub.
Replacement devices enroll through this same connection screen with a fresh
scoped token; Keychain credentials are not copied between devices.

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
under `life-ui/replicas/`, per-workspace graph groups, and alert preferences,
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
mark-all-read actions. Launch an Apple app with
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

## Core and build ownership

life-data owns the source. Regenerate the committed browser and native
artifacts from one source checkout:

```sh
bun run bundle:core /path/to/life-core/src/validate.ts

# Rebuild the native adapter and graph from this checkout alone.
bun run bundle:native
bun run bundle:graph
```

The full core bundles carry the same source SHA-256; validator-only artifacts
carry the validator's SHA-256. Generated bundles contain no developer paths.
A clean Life UI checkout builds without a sibling life-data checkout.
CI regenerates both native resources and rejects a stale committed artifact.
Never patch generated files by hand. `scripts/native-core.ts` is the native
adapter, not a second validator. No native SQL callbacks are exposed to web
content.

`apps/web`, `apps/macos`, `apps/ios`, `packages/LifeKit`, `packages/core` and
`scripts` follow the repository's platform boundaries. The independent
mockup remains in `../life-ui-mockup`.

## Current limits

This is an MVP implementation in progress. Enforced SQL invariants and custom
triggers fail closed until the complete local rule/journal engine is connected.
Missing references must be included in the replica before editing them. A
skipped table is not automatically browsed remotely. Search uses bounded SQL
queries, not FTS. Saved views, full grid keyboard editing, rich Markdown
editing/editor islands, and Notes migration remain open work.

Native references currently accept row IDs; multi-value/JSON fields use source
editors. Native browse supports search, trash and pages of 100 rows, with no
saved views or full grid editor. Sync runs on connection and explicit request,
not in the background. Device-approval enrollment, automatic token issuance,
rich Markdown editing and iOS graph presentation remain open work.

Browser OPFS availability is required. There is no remote read-only fallback,
service worker, or promise that a closed web app can cold-load without a
network connection. An already-open workspace can edit its local data offline.

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

- Choose GitHub visibility before creating the remote; no visibility is assumed.
- `.env.tpl` is the Life UI CI bootstrap manifest. Run
  `op-project-bootstrap /path/to/life-ui/.env.tpl --repo <owner>/life-ui`
  after the remote exists. Credentials must be minted for Life UI. Cloudflare
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
