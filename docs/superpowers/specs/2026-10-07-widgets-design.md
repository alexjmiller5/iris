# Configurable iOS widgets and capture controls

Status: approved for implementation.

## Outcome and scope

People can put useful slices of any catalogued table on their Home Screen,
see a private count on the Lock Screen, and start a new record without finding
its table first. Configuration uses the person's workspace and saved views;
the product contains no personal table names, columns, rows, or schedules.

The first release contains Table / saved-view list, Today, Count, and Quick add.
Pinned-record widgets, charts, and Live Activities are outside this release.
Sidebar table pins are a separate feature described in
[the sidebar design](2026-10-07-sidebar-pins-design.md).

Existing decisions remain: Spotlight titles only with per-table opt-in, capture
as a draft before Save, and count-only Lock Screen presentation. Spotlight and
the share extension retain their own implementation and acceptance scope.

## User experience

| Surface    | Configuration and behavior                                                                                                                                                                                                                                        |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Table list | Select a workspace and table, optionally a saved view. Show current catalog display titles, preserving the view's filters and order. Small opens the selected view; medium and large also open individual records. Multiple widgets can select different sources. |
| Today      | Select a saved view with a relative Today filter. Reuse its timezone and day-start policy. Offer setup in the app if none exists; never guess a task table, date column, or completed status.                                                                     |
| Count      | Select the same table/view sources. Show the matching local-record count, with explicit partial, stale, or capped presentation where applicable. Tapping opens the view.                                                                                          |
| Quick add  | Select a writable table. Open a new prepared draft in the app, optionally carrying Shortcuts text. No row is created until explicit Save succeeds.                                                                                                                |

List widgets support small, medium, and large Home Screen families. The provider
loads at most 20 titles; the view fits fewer rows as text size increases rather
than shrinking the text. A small widget opens its source, avoiding unsupported
multiple row links. Titles are plain text, never rendered Markdown or attachments.

Accessory families show counts and generic labels, with no record or custom table
titles in visible text or accessibility labels. The Quick add Lock Screen control
also uses a generic label and requires authentication before opening a draft.
Home Screen title views are privacy-sensitive in system-redacted contexts.
Placeholders and gallery previews use synthetic data only.

Quick add is available as an ordinary widget and App Shortcut on the existing
iOS 17 baseline. Control Center, Lock Screen controls, and Action button support
are availability-gated for iOS 18 and later. New foreground execution APIs are
gated separately; this work does not raise the application's deployment target.

The in-app daily-tasks section remains above the configured Notes destination.
Its source is selected by table/view identity at runtime, and it uses the same
calendar and query semantics. It is a distinct acceptance check from installing
a Home Screen widget. No special table name is compiled into the layout.

## Architecture and alternatives

Use the accepted transferable-plan approach: the existing core compiler emits
a read-only query whose explicitly typed calendar operands can be rebound when
the extension runs. A host-published SQLite generation supplies its data.

An array of host-generated future snapshots alone expires if the app stays
closed. Running JavaScriptCore and the ordinary workspace writer in the extension
would broaden its capabilities and startup work. Neither is the chosen approach.

The units are:

1. **Life Data core:** refactor `core/src/view.ts` once so eager queries and
   transferable queries share validation, predicates, ordering, and binding
   order. Add the canonical DTO and operation to `core/contract/core.json` and
   regenerate consumers through the existing generator and bundler.
2. **Extension support target:** Foundation, generated portable DTOs, shared
   calendar resolution, identity encoding, and a read-only system SQLite executor.
   Extract those shared components once from LifeKit; keep existing public
   entry points forwarding compatibly. No dependency on LifeKit's JSC engine,
   editor resources, writer, credential store, or networking.
3. **Host publisher:** serialize snapshot capture with NativeWorkspace, create
   a coherent SQLite backup and metadata generation, then publish it atomically
   in a Life UI App Group. This is a regenerable copy of the app's own local
   replica, not a move of the live database and not another project's storage.
4. **Widget extension:** App Intent configuration entities, timeline providers,
   bounded rendering, and identity-only navigation actions.
5. **Host intent handlers:** foreground Quick add, Open Today, and existing
   core-backed person lookup. Draft preparation and guarded navigation remain
   in the app; lookup does not introduce an extension-side search engine.

## Core plan contract

The generated plan carries a version, result kind, a bounded SELECT, and an
ordered parameter array. Every parameter is either a literal SQL scalar or a
declared `today`, `start`, or `end` calendar slot. Slots are emitted at the
compiler's binding sites, never inferred from SQL text or matching literal values.

The plan also carries explicit output columns and guards for workspace/replica
identity, saved-view ID and revision when selected, schema fingerprint, relevant
catalog fingerprint, and calendar policy. Catalog identity includes display
column, types, and ordered options used by compilation. Direct-table queries
still carry schema/catalog/workspace guards. Unknown plan versions fail closed.

Count uses the same predicate builder, without inheriting the list's 20-row
display limit. The first version counts up to 10,001 matching IDs and renders
`10,000+` above 10,000. This is an explicit lower bound, never a fabricated exact
total. Execution has a cancellation/work budget as well as bounded output;
`LIMIT` alone does not bound the cost of filtering or sorting a large table.

Nonempty full-text search is explicitly unsupported by the first read-only
plan. Existing core search drains an indexing queue and cannot safely be copied
into a SELECT-only reader. The configuration displays the reason and an Open
in app action instead of silently dropping search or returning empty results.

## Publication, rollover, and failure behavior

Prepare the SQLite backup and its plan metadata from one serialized, stable
workspace snapshot. Verify the compiled guards against the completed backup
before publication. Write into a new generation directory and atomically replace
a small current-generation pointer only after all files are complete. Readers
hold the selected generation throughout guard validation and query execution.
Interrupted publication leaves the previous generation usable. Cleanup never
removes a generation held by a reader.

The executor opens the snapshot read-only and validates guards and executes the
query in one read transaction. It accepts exactly one read-only statement and
rejects writes, attachments, PRAGMAs, and connection-changing statements. It
never initializes schemas or drains FTS. The extension has no hub credentials
and performs no sync or network request.

Use the shared `calendarContext(timeZone:now:dayStartMinutes:)` at each provider
read, including when the containing app has remained closed. Today is a date
label; start and end are exact UTC interval endpoints. Preserve the existing
date-only/timestamp rules, next-valid-time DST gap behavior, and first-occurrence
fold behavior. A missing day-start setting means midnight.

Generate the current entry and the next predictable day-boundary entry using
the same plan with newly computed slots, and request a new timeline at the
boundary. These future entries supplement runtime rebinding; they are not a
finite substitute for it. iOS schedules actual refreshes, so the UI always
distinguishes the query's effective day from the data publication time.

After successful local writes, sync reconciliation, and view/catalog changes,
the app republishes affected content and requests relevant timeline reloads.
Publication is coalesced, bounded, and lower priority than foreground navigation.
Host closure does not imply background sync. A current calendar result can still
come from an older local replica and must not claim remote freshness.

Ordinary refresh, publication, or guard failures retain the last successful
result with an as-of/stale indication and an Open/Refresh affordance. A failed
read must never appear as a current empty list or zero count. Partial replication
is identified separately. Explicit removal of widget access, workspace removal,
or host-observed loss of authorization invalidates retained content instead of displaying it
as a stale fallback. An empty verified result is a valid empty state.

Private publication and fallback files use supported file protection and remain
outside source control and backups where appropriate for a regenerable cache.
Protected-data unavailability produces a safe placeholder; it is not a reason
to weaken protection or fetch credentials. Body values present in the SQLite
copy are never included in timeline entries, intent entity labels, or diagnostics.

## Identity, drafts, and deployment

Entity identities compose the existing workspace binding and exact table/view/
row keys. Preserve byte-exact UTF-8 identities. Local-only workspaces remain
device-local; Shortcuts must explain an unavailable binding on another device.
Resolve existing IDs in batches and provide bounded picker suggestions.

Widget links reuse `NativeDeepLink` and current destination resolution. A link
does not enroll, silently switch workspaces, discard a live editor, or bypass
the pending-link flow. A selected row is re-read in the host before editing.

Quick add rechecks current catalog and writeability, then installs a distinct
recoverable draft through the ordinary record editor. Retried intent delivery
reuses its draft handoff rather than creating multiple records. Input text is
data, never SQL, and is not embedded in a public URL. No Save is inferred from
launching the intent or opening the draft.

XcodeGen adds an embedded widget target with its own bundle identifier and a
Life UI-only App Group. The current wildcard Ad Hoc profile is not assumed to
authorize that capability. Extend the existing signing flow to match and verify
each app/extension profile, common team and App Group, entitlements, device
eligibility, and identical build versions. Use the existing distribution
certificate; no replacement signing credential or shared Keychain group.

## Verification and acceptance

The widget shall read only a coherent, guard-valid publication. When its timeline
provider runs, it shall resolve calendar slots for the effective read time.
If validation or execution fails, it shall show an unavailable or explicitly
stale result, never a current zero inferred from failure. While the device is
locked, accessory content shall expose no record titles. When Quick add runs,
the app shall prepare a draft and shall create no record before explicit Save.

- Start with failing core tests comparing actual plan execution to eager
  compileView at the day boundary, DST gap/fold/skipped dates, null and mixed
  date-only/timestamp values, ordered options, and literals equal to calendar
  values. Include Count results above the display and count caps.
- Reject changed view/schema/catalog/policy/workspace and mismatched publication
  generations. Verify real SQLite read-only enforcement, canceled expensive
  queries, interrupted publication, and old-generation reader lifetime.
- Mutation checks remove slot tagging, a catalog guard, snapshot pairing,
  count capping, and stale presentation independently; each must be caught.
- Run a real extension provider against synthetic publications with the host
  stopped. Verify rollover without host timers, offline reads, configuration of
  two different tables, protected-data failure, and missing targets.
- Verify actual widget layouts at default and accessibility text sizes, native
  VoiceOver labels, light/dark/tinted appearances, and narrow/small families.
- Test Quick add through the installed intent and app UI: cancel/keep existing
  draft, accept new draft, save, reopen, and assert exactly one stored row.
- Verify in-app daily-task placement independently. Preserve rich Markdown,
  navigation, sync, and existing editor acceptance.
- Signed physical-device checks cover gallery discovery, multiple Home Screen
  instances, Lock Screen privacy, Shortcuts/control discovery, widget navigation,
  actual app-closed rollover, and VoiceOver. Simulator results do not substitute
  for those checks or complete the whole accessibility task.

## Platform references

- [WidgetKit strategy](https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy)
- [Widget timelines](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Widget configuration intents](https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget)
