# Native link host implementation plan

> Implement with superpowers:executing-plans. Parent approved the bounded design.

**Goal:** Copy and explicitly open workspace-bound native destinations without replacing editors or switching workspaces.

**Architecture:** WorkspaceModel owns the installed binding and local identity store. WorkspaceView retains one pending request and reuses fresh destination resolution and guarded activation. URL receipt alone never navigates.

**Spec:** `docs/native-deep-links.md` and the approved host contract below.

**Constraints:** No core, generated bundle, Fields/FileInput, QuickFind or System-table changes. Compiler starts only after the shared slot is released. Xcode and actual iOS runs belong to the Apple verification owner.

## Prepared test checkpoint

The new tests are definitions only and have not run. The intended host APIs
(`WorkspaceModel.linkBinding`, `canCopyLink`, `linkError`, `linkURL(for:context:)`,
`linkedDestination(_:)` and `PendingNativeLink`) are not implemented yet. This
checkpoint therefore does not compile the new test suite and is not ready to merge.
No new production behavior is included. Observe behavioral RED with minimal
compilable stubs before implementing the lifecycle phase.

The first phase is model/lifecycle only. Keep the prepared iOS tests for the
subsequent host phase; neither their presence nor a SwiftPM pass proves actual
editor, system URL or clipboard behavior. Their opt-in requires a nonempty valid
selected simulator UUID equal to `SIMULATOR_UDID` before any app launch.

## Steps

- [ ] Add real temporary-file/SQLite lifecycle tests and controlled pending-request tests; observe behavioral RED with minimal stubs.
- [ ] Retain binding across Forget; clear on client replacement; load local identity without writing; create only for explicit Copy; recheck stamp before matching.
- [ ] Add one pending-link state, explicit Open/Dismiss, generation/request/UTF-8 query guards, and shared fresh resolver activation. Keep Issues/reference handoffs intact.
- [ ] Add host and saved-record Copy controls, a small editor waiting notice, scheme registration and app privacy manifests.
- [ ] Add actual iOS URL tests covering normal cold launch, dirty cancellation and copy/open. Run through the Apple owner; do not substitute unit proof for UI evidence.
- [ ] Run focused GREEN, meaningful mutants and restored full SwiftPM suite; review source, document exact limits and checkpoint evidence.

## Review boundaries

Unread identity preferences must never be replaced. A replaced local file cannot accept its prior link. A forgotten replica remains the same link workspace. Stale completion cannot consume a newer pending request, including byte-distinct identifiers. Pending writes, editors and prepared sheet handoffs cannot be replaced. URL payloads never carry credentials, file paths, labels or draft content.
