# Life UI

Local-first web and native Apple clients for catalogued life-data databases.
Title: Life UI; slug: life-ui; Apple product: LifeUI. No PWA or analytics.

## Layout and contracts

- `apps/web`: Svelte 5/SvelteKit, Tailwind 4, Cloudflare Worker static assets.
  SQLite runs through wa-sqlite/OPFSCoopSyncVFS in a dedicated Worker.
- `apps/ios`, `apps/macos`: XcodeGen SwiftUI targets consuming LifeKit.
- `packages/LifeKit`: serialized JavaScriptCore facade, GRDB adapter, native
  workspace, URLSession transport, Keychain storage and bundled graph island.
- `packages/core`: generated TypeScript declarations and JS artifacts. Core
  implementation belongs to life-data. Regenerate with
  `bun run bundle:core <path-to-life-core/src/validate.ts>`. Never patch generated
  files. Native and browser full-core headers identify the same source SHA-256.
- `scripts/native-core.ts`: native adapter over the generated shared core.
  It must not become a second validator, view compiler or sync implementation.
- `apps/web/vite.graph.config.ts`: self-contained native graph HTML built from
  the same SchemaGraph component. No external assets or network access.
- `scripts`: build and fixture test operations. No credentials or data exports.

The supported service dependency is the life-data hub API with independently
minted client credentials. Never bind its D1/R2 or borrow infrastructure tokens.
Life UI owns its Worker, Access application, vault and deployment credentials
when provisioned. `.env.tpl` is the operator/CI bootstrap manifest; its values
never enter the browser bundle. Workers Scripts Write is account-scoped and
requires an explicit scope decision before provisioning. No deploy workflow is
enabled, and remote visibility is an owner decision.

The usage/notifications API is owned by life-data; never add competing hub
endpoints here. life-core owns service validation, feed pagination and presentation
policy. Isolate cached state by signed-in deployment, deduplicate native/feed
alerts by event id, and never expose bearer tokens in device lists. First contact
baselines history; delivery checkpoints advance after successful scheduling.
Native permission is requested only by the explicit Enable alerts action.
Usage is deployment-scoped; provider-wide billing APIs do not belong in clients.

## Data integrity

Components call the shared write path; no component SQL writes.
The SQL adapter read path accepts exactly one read-only statement. Parse the
whole input before stepping; reject writes and connection-changing commands
from catalog options/default expressions. Trusted schema replay stays separate. Pass the opened
record's `updated_at` as `expectedUpdatedAt` to prevent stale editor overwrites.
Keep drafts separate from the stored row and reconcile successful writes without
silently discarding later typing. Preserve unknown existing multi-select values.

Whole Worker requests and whole native asynchronous requests are serialized.
Native SQLite transactions retain ownership across awaited JS callbacks.
Browser operations hold a Web Lock across tabs; native sync holds the
Python-compatible `<database>.sync.lock`. A demo database must never sync.
Application state lives in OPFS/Application Support, never the source checkout.

Core system tables and `catalog_tables.kind: system` are read-only. SQL
invariants and custom triggers currently fail closed pending a complete local
validation/journal engine. Missing replica references must not be guessed valid.
Skipped-table data can be incomplete and the UI must identify that state.
Pending UI edits await the core's own valid receipt; this is not the CLI queue.
Never report a write as saved or a round as synced before its promise succeeds.

Credentials cross the supported client seam as a hub URL and app-issued token.
Browser tokens are session-only; native tokens use Keychain. Provider credentials
stay service-side. Native SQL callbacks are trusted JSC-only, never exposed to
web content. WebKit input uses parsed arguments and validated messages; the graph
resource forbids navigation/network and contains its own script/style CSP hashes.

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

Web design tokens live in `apps/web/src/routes/layout.css`; use Tabler UI icons,
accessible controls, keyboard focus and narrow-screen layouts. Native views use
SwiftUI semantic styles. Native graph changes must regenerate the bundled island.
