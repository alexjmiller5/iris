# Life UI

Local-first web and native Apple clients for catalogued life-data databases.
Title: Life UI; slug: life-ui; Apple product: LifeUI. No PWA or analytics.

## Layout and contracts

- `apps/web`: Svelte 5/SvelteKit, Tailwind 4, Cloudflare Worker static assets.
  SQLite runs through wa-sqlite/OPFSCoopSyncVFS in a dedicated Worker. The pinned
  FTS5-enabled JS/WASM pair is in `vendor/wa-sqlite`; regenerate through its Nix
  package and `scripts/build-wa-sqlite.ts`, preserving the matching API/VFS pin.
- `apps/ios`, `apps/macos`: XcodeGen SwiftUI targets consuming LifeKit.
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
- `scripts/native-core.ts`: native adapter over the generated shared core.
  It must not become a second validator, view compiler or sync implementation.
- `apps/web/vite.graph.config.ts`: self-contained native graph HTML built from
  the same SchemaGraph component. No external assets or network access.
- `apps/web/vite.editor.config.ts`: self-contained Markdown editor island using
  the same Milkdown component as the web client. `lifeEditor.setDocument` accepts
  a draft ID, source, label and read-only state; `getDocument` returns the live
  snapshot. Native hosts reject stale IDs and collect the snapshot before Done.
  Keep Markdown as storage, preserve untouched source, and render imported HTML
  inert. The island has no network, SQL or credential access.
- `scripts`: build and fixture test operations. No credentials or data exports.

The supported service dependency is the life-data hub API with independently
minted client credentials. Never bind its D1/R2 or borrow infrastructure tokens.
Life UI owns its Worker, Access application, vault and deployment credentials
when provisioned. `.env.tpl` is the operator/CI bootstrap manifest; its values
never enter the browser bundle. Workers Scripts Write is account-scoped and
requires an explicit scope decision before provisioning. No deploy workflow is
enabled for branch pushes. The public repository is `alexjmiller5/life-ui`.

Mac distribution uses `.github/workflows/release-macos.yml`, triggered only by
explicitly approved stable version tags. It stamps the tag version, builds both
Apple Silicon and Intel, signs with Developer ID, notarizes, staples, checks
Gatekeeper and publishes the archive before updating the configured Homebrew tap.
The tap is a separate job so its failure never requires republishing an asset.
It only advances stable versions; identical version/hash retries are no-ops,
while conflicting hashes or unsupported version/checksum formats fail closed.
The documented Apple Signing vault exception supplies shared signing/notary
material and the tap credential to the project CI service account. This grants
CI read access to that shared vault; it is not app runtime or consumer auth.
`HOMEBREW_TAP_REPOSITORY` is a repository variable, not a client preference.
Ordinary changes never bump a version or push a release tag.

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

Web destination URLs carry only table, stable saved-view and record identifiers.
Resolve them against the explicitly opened workspace's fresh catalog, saved view
and full row. Use SvelteKit navigation hooks for browser history so cancelling
Back restores the URL as well as the draft. Do not use shallow history entries
that bypass those hooks. Ignore superseded lookup replies and block writes while
resolving a linked record. Unsaved view settings and credentials stay out of URLs.

Saved views use the core contract and the canonical `core/schema/saved-views.json`
manifest vendored by `bundle-core.ts`. Only explicit app-owned local/sample
initialization may create missing storage; replicas receive logged DDL through
sync, and external files or name collisions are never adopted or repaired.
The core bundle source hash includes the manifest. Keep the applied view's
revision until the user reopens it, even when a refreshed list has a newer one.
Definitions control layout; edit queries must return full rows, not the
saved definition's SQL column projection. Preserve imported multi-column sorts.
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
Native permission is requested only by the explicit Enable alerts action.
Usage is deployment-scoped; provider-wide billing APIs do not belong in clients.

## Data integrity

Components call the shared write path; no component SQL writes.
The SQL adapter read path accepts exactly one read-only statement. Parse the
whole input before stepping; reject writes and connection-changing commands
from catalog options/default expressions. Trusted schema replay stays separate. Pass the opened
record's `updated_at` as `expectedUpdatedAt` to prevent stale editor overwrites.
Keep drafts separate from the stored row and reconcile successful writes without
silently discarding later typing. Web body autosave writes only editable Markdown
columns on existing rows; it updates the acknowledged baseline without replacing
the live draft. Failed identical patches must not loop. Preserve unknown existing
multi-select values.

Session Undo uses the core's one volatile receipt. Display the action as
"Undo last saved change" and submit that displayed receipt ID; never reconstruct
inverses or expose history as undo. Pause body autosave before the request without
flushing the draft. Merge unchanged fields from the returned row while preserving
newer drafts; those drafts require an explicit Save before autosave resumes.
Failures retain the draft and action. A returned tombstone stays read-only until
explicit Restore, which also preserves the retained draft. Text-editor Undo stays
separate. Reopening a workspace clears the session action.
An affected dirty grid cell moves into the record review panel after Undo,
using the receipt's full baseline plus only the newer raw cell value. Clear an
unchanged affected cell; leave another row's cell draft untouched. Creation Undo
retains the draft beside a read-only tombstone, and Restore preserves it.

Native recovery journals are private, atomic and isolated per editor. Persist
the latest draft and any unacknowledged write before awaiting its receipt. Keep
app-owned workspace identities stable across container relocation; external
databases use canonical paths. Recovery never rebases an old draft implicitly.
Copy/review into a fresh editor or explicitly discard the retained draft.
Record and reference IDs are opaque UTF-8 values. Native equality, collection
keys and SwiftUI row identity must preserve their exact bytes; Swift String
canonical equivalence must not merge records, recoveries or reference selections.
Keep the original String values at the core boundary.

Whole Worker requests and whole native asynchronous requests are serialized.
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
Pending UI edits await the core's own valid receipt; this is not the CLI queue.
Never report a write as saved or a round as synced before its promise succeeds.
Web sync failures also broadcast database changes: individual pulls and receipts
can commit before a later request fails. Refresh rows, counts and writeability
in every open tab while retaining editor drafts and the original sync error.

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

## Development and verification

`bun install --frozen-lockfile`, then `just dev`. `just test`, `just check`,
and `just build` cover web and Apple targets. `just fmt` formats owned source.
The README documents browser smoke commands and a real Worker synthetic hub.
Fixtures are synthetic only; never copy live personal data into tests or docs.

`project.yml` is authoritative; generated Xcode projects and Info.plists are
ignored. Child justfiles expose platform run/test/check/build. Caches and derived
data live outside the synced source tree with environment overrides. Do not
open Xcode on a headless build host. Simulator tests can use local signing;
unsigned builds need no Apple account. Ad Hoc, phone installation, Developer ID,
notarization and installed distribution are separate verification steps.

Test behavior before implementation, then verify real SQLite, JSC and browser
flows. Run the full applicable suites after the final source change. Use an
isolated simulator if another project is driving the shared default device.

Web design tokens live in `apps/web/src/theme.css`; use Tabler UI icons,
accessible controls, keyboard focus and narrow-screen layouts. Native views use
SwiftUI semantic styles. Native graph changes must regenerate the bundled island.
`islands.css` explicitly scopes Tailwind sources to the embedded components;
unrelated web files must not change native artifacts. Verify this with
`bun scripts/test-island-builds.ts` before publishing regenerated resources.
