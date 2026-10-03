# Native Recents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver native recents persistence and presentation state for later host integration.

**Architecture:** Use the common byte-exact `NativeDestination` and fresh
`NativeDestinationResolver`. A private atomic preference store and an observable
model manage at most eight identities and transient resolved labels.

**Tech Stack:** Swift, Foundation, Observation, Swift Testing, existing LifeKit JSC core.

**Spec:** `docs/superpowers/specs/2026-10-03-native-recents.md`

## Global Constraints

- New model/store/tests only; no views, main, generated artifacts or resources.
- NativeDestination is Codable/Hashable with byte-exact identity; no fallback DTO.
- Only navigationSucceeded after the host UI commit records history; sample is memory-only.
- SwiftPM runs require the Apple owner's explicit isolated-cache lease.

## Review Focus

- Unread, malformed or future-version files survive subsequent mutations byte for byte.
- Canonically equivalent Unicode IDs remain distinct across reload and removal.
- App-container relocation preserves identity without sharing external workspaces.
- A stale window cannot erase another window's recent additions.
- Removed entries and replaced workspace results cannot reappear after delayed resolution.

## Task 1: Private preference store

**Files:** `NativeRecentsStore.swift` and `NativeRecentsStoreTests.swift` under
LifeKit's existing source/test directories.

**Interface:** `init(root: URL, workspace: URL)`; `load() throws -> [NativeDestination]`;
`update(_ change: ([NativeDestination]) -> [NativeDestination]) throws -> [NativeDestination]`.
Derive the scope with `EditorDraftStore(root: root/drafts, workspace: workspace).directory`.

- [x] Add failing real-file tests for roundtrip, raw-ID-only payload, cap/reordering,
  exact Unicode removal, workspace relocation/isolation, read failure latch,
  concurrent store instances and private permissions.
- [x] Under the granted lease, run focused tests against minimal compiling stubs;
  retain the behavioral RED log before implementation.
- [x] Implement bounded normalization, version decoding, read-before-update,
  fail-closed read handling and atomic private writes.
- [x] Run focused tests and mutations removing each safety property.

## Task 2: Observable recents projection

**Files:** `NativeRecentsModel.swift` and `NativeRecentsModelTests.swift`.

**Interface:** optional store, resolver closure and current-context predicate;
`refresh() async`, `navigationSucceeded(_:) async`, `remove(_:) async`, `cancel()`;
read-only entries and storageError. Resolved entries contain current label,
loading/unavailable state and trash state, identified by NativeDestination.

- [x] Add RED tests proving resolver/refresh never record, explicit completion does,
  sample has no persistence, storage failure still updates memory, and stale or
  removed entries cannot be republished.
- [x] Add real JSC tests through the common resolver for changed row/view labels,
  full rows, tombstones, missing targets and service-owned table metadata.
- [x] Implement projection with per-refresh generation and current-context guards.
- [x] Catch mutations that record during resolution, normalize IDs, prune missing
  entries, overwrite unread storage or accept stale results.
- [x] Run the full LifeKit suite and permitted static checks after final changes.
- [ ] Document the host hook, review, commit all branch changes and publish the
  feature branch for parent integration; no merge or UI-completion claim.

## Verification

The focused recents suite passes 19 tests (24 parameterized cases). The complete
LifeKit suite passes 196 tests. Fourteen behavior mutations were caught, including
an inaccessible-directory regression reproduced with real permission changes.
Reads treat only Cocoa fileReadNoSuchFile as an empty preference; other read
failures preserve the file and disable persistence for that model session.

Final publication waits for the common resolver's NOCASE identifier review.
