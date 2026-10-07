# Synced Sidebar Pins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. The user selected independent execution in this session without other agents.

**Goal:** Persist ordered sidebar table pins in the workspace's synced data across web, iOS, and macOS.

**Architecture:** Life Data owns a recognized canonical storage manifest, generated pin operations, normal validated writes, rename propagation, and provisioning. Life UI imports that contract and renders receipt-backed pin state below Recents through its existing guarded navigation.

**Tech Stack:** TypeScript/Bun/SQLite, Python, generated Swift DTOs, GRDB/JavaScriptCore, Svelte 5, SwiftUI.

**Spec:** [Approved sidebar design](../specs/2026-10-07-sidebar-pins-design.md).

## Global Constraints

- One ordinary synced `sidebar_pins` table; no device-local preference fallback.
- Preserve unrelated files and all shipped navigation, editor, and sync behavior.
- Per-table deterministic identities, soft deletes, exact revision guards, normal write receipts.
- Existing iOS 17/macOS 14 targets; no new runtime dependency or personal fixture data.
- Core source and schema changes belong in Life Data; regenerate all UI artifacts.

## Review Focus

- Re-pin after sync must restore the tombstone, not create a second row (Task 2).
- Missing target must remain removable without a successful destination lookup (Tasks 2, 4).
- Concurrent equal ordering positions must still allow Move up/down (Task 2).
- A failed refresh or write must preserve the last acknowledged pins and active editor (Task 4).
- Renames with future-clock revisions must survive push discovery and a second replica (Task 3).

### Task 1: Actual sidebar baseline and durability fixture

**Files:** create `scripts/test-sidebar-pins.ts`; reuse `scripts/source-navigation-cdp.ts`, `scripts/workspace-regression-hub.ts`, `scripts/test-origin.ts`.

**Interfaces:** consumes an owned synthetic page via `LIFE_UI_TEST_URL`, `LIFE_UI_TEST_TARGET`, and an explicit matching core/service checkout; produces screenshots/logs outside the repo and assertions reusable after implementation.

- [x] Create a real-browser test that opens a synthetic workspace, expects table Pin controls, and pins two tables in nonalphabetical order. Assert the Pinned section is below Recents and each table is absent from the ordinary section.
- [x] Run on current UI and preserve the expected missing-control failure before product changes.
- [x] Extend the same fixture after core integration to reopen, sync, read from a fresh replica, reorder, unpin, and preserve a dirty editor when navigation is canceled.

### Task 2: Core pin operations and generated contract

**Files:** create Life Data `core/schema/sidebar-pins.json`, `core/src/sidebar-pins.ts`, `core/test/sidebar-pins.test.ts`; modify `core/contract/core.json`, `core/src/index.ts`, `core/src/operations.ts`, `core/src/undo.ts`, `core/package.json`; regenerate TS/Swift contract files.

**Interfaces:** `listSidebarPins(db, {}) -> SidebarPinList`; `pinTable(db, {table, expectedUpdatedAt}) -> SidebarPinList`; `unpinTable(db, {id, expectedUpdatedAt}) -> SidebarPinList`; `moveTablePin(db, {id, direction, expected}) -> SidebarPinList`. `SidebarPinList` contains all recognized rows including tombstones and `unavailable: string | null`; hosts render active rows only. Each pin has `id`, `tbl`, integer `position`, `updated_at`, `deleted_at`, and per-target `unavailable`. `expected` is the complete selected active list of `{id, updated_at}` for a move. New pin expects null, restore expects its tombstone revision. Normal session admission serializes these operations; sidebar mutations do not publish a partial multi-row record-Undo action.

- [x] Write real-SQLite tests asserting `listSidebarPins` reports missing storage without creating it and that pinning survives closing/reopening a file-backed database.
- [x] Run `bun test core/test/sidebar-pins.test.ts`; verify expected missing operation failure.
- [x] Add the canonical manifest and generated DTO/operation definitions. Implement recognition, deterministic `pin:v1:<hex UTF-8 table key>` identity, list ordering with binary tie-break, pin/restore, tombstone, and guarded neighbor moves using the ordinary writer inside one outer transaction.
- [x] Add tests for collisions, malformed arguments, input mutation during awaits, stale/null revisions, missing targets, readonly storage, equal positions, boundary moves, pending markers, history, and rollback after the second move write fails.
- [x] Exercise the actual Worker handler with two replicas and verify independent pins converge without local schema push, and stale local commands fail before writing.
- [x] Run `bun test` from `core`; run generated-contract check and TypeScript check with existing dependencies. Mutate revision guard, alphabetical ordering, persistence, and tombstone restoration individually and require relevant tests to fail; restore and rerun.
- [x] Commit and push the coherent core slice with test receipts.

### Task 3: Provisioning and rename continuity

**Files:** create Life Data `tests/test_sidebar_pins.py`; modify `src/life_data/catalog.py`, `src/life_data/__init__.py`, and owning current-state documentation as needed. Package the same canonical manifest rather than maintaining a second schema literal.

**Interfaces:** generic supported setup installs the manifest through normal logged DDL and catalog writes; recognized `sidebar_pins` references follow `rename_table(path, old, new)` using the existing rekey/tombstone convention.

- [x] Write Python tests asserting generic provisioning matches the TypeScript manifest, repeats safely, and refuses a foreign table without writes.
- [x] Write rename tests for active/deleted pins, retained order, forward-clock revisions, collision rollback, and a second sync replica.
- [x] Run those tests RED, implement the smallest supported provisioning/rename changes, then rerun GREEN.
- [x] Mutate rename propagation and verify failure. Run the full Python and affected Worker/core suites; commit and push.

### Task 4: Web and native sidebar integration

**Files:** create Life UI `apps/web/src/lib/sidebar-pins.ts`, `SidebarPins.svelte`, their tests, `packages/LifeKit/Sources/LifeKit/NativePinsModel.swift`, and `packages/LifeKit/Tests/LifeKitTests/NativePinsTests.swift`; modify `SidebarTables.svelte`, `apps/web/src/routes/+page.svelte`, database dispatch, native dispatch, `WorkspaceSidebar.swift`, `NativeSidebar.swift`, `WorkspaceModel.swift`, local/sample initialization, and the core bundler's manifest inclusion.

**Interfaces:** adapters expose the generated Task 2 operations. A host pins model retains `SidebarPinList`, loading/mutating/error state, and workspace generation; receipts and refreshed catalog drive presentation, never local preferences. Rendering receives ordered active pins and current catalog; navigation reuses existing callbacks.

- [x] Regenerate from the exact tested Life Data source and assert TS, native resource, and manifest hashes agree.
- [x] Write failing controller/model/component tests for receipt-only state changes, failure retention, missing target Unpin, late workspace replies, grouping/deduplication, selected pin identity, and keyboard actions.
- [x] Implement Pin/Unpin and Move up/down, Pinned section below Recents, and refresh on existing sync/foreground/change events. Preserve dirty editors and ordinary alphabetical/System grouping.
- [x] Run focused tests, whole web/core bridge checks, and full native unit tests. Mutate grouping and failed-write retention; verify failures, restore, and rerun.
- [x] Run Task 1 real browser fixture GREEN including fresh-replica sync and reopen; verify no localStorage pin authority.
- [ ] Add and run dedicated actual native UI tests in `apps/ios/UITests/SidebarPinsUITests.swift` with synthetic fixture setup. Verify pin/order/reopen, keyboard/VoiceOver labels, and guarded navigation.
- [ ] Commit, push, inspect CI through completion, and document exact source/resource acceptance.

### Task 5: Review and delivery

- [x] Review both repository diffs against the approved spec independently of the implementation pass. The user requested no other-agent involvement; perform and label an author self-review.
- [x] Fix substantive findings with RED/GREEN evidence and rerun applicable suites.
- [ ] Deliver reviewed changes through existing repository release flows, preserving signing/profile safeguards. Verify deployment receipts, then installed acceptance where available.
- [ ] Update the existing sidebar task with exact commits, checks and remaining scope; keep it open for saved-view pins/stream screens. Remove only owned synthetic state and processes.

## Verification scope

Core: 1,260 tests; Python: 636 tests; web: 357 tests; native: 542 tests with two preexisting known issues. Real browser pin/order/unpin/restore, dirty navigation, OPFS reopen and fresh-replica sync passed. Native model/file-reopen tests passed; actual iOS sidebar interaction is in progress. Whole-view VoiceOver and physical-device acceptance remain separate, unverified scope.
