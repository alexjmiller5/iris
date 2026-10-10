import Foundation
import Testing

@testable import IrisKit

@MainActor
struct EditorAutosaveTests {
  let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
  ]
  let original: WorkspaceRecord = [
    "id": .string("fixture"), "title": .string("Original"),
    "body": .string("Old"), "updated_at": .string("revision-1"),
  ]

  @Test func autosaveSerializesLaterTypingWithReceiptRevision() async throws {
    var calls: [(WorkspaceRecord, WorkspaceRecord?)] = []
    var first: CheckedContinuation<WorkspaceRecord, any Error>?
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: nil, debounce: .seconds(60), typingDelay: .seconds(60)
    ) { patch, baseline in
      calls.append((patch, baseline))
      if calls.count == 1 {
        return try await withCheckedThrowingContinuation { first = $0 }
      }
      return baseline!.merging(patch) { _, new in new }.merging([
        "updated_at": .string("revision-3")
      ]) { _, new in new }
    }
    editor.setValue("First body", for: "body")
    let flush = Task { try await editor.flushAutosave() }
    for _ in 0..<100 where first == nil { await Task.yield() }
    #expect(first != nil)
    #expect(editor.saving)
    #expect(!editor.saved)
    editor.setValue("Later body", for: "body")
    editor.setValue("Typed during the write", for: "title")
    let secondFlush = Task { try await editor.flushAutosave() }
    first?.resume(
      returning: original.merging([
        "body": .string("First body"), "updated_at": .string("revision-2"),
      ]) { _, new in new })
    try await flush.value
    try await secondFlush.value
    #expect(calls.count == 2)
    #expect(calls[0].0 == ["id": .string("fixture"), "body": .string("First body")])
    // Later edits, of any field, go in the next write with the receipt's revision.
    #expect(
      calls[1].0
        == [
          "id": .string("fixture"), "body": .string("Later body"),
          "title": .string("Typed during the write"),
        ])
    #expect(calls[1].1?["updated_at"] == .string("revision-2"))
    #expect(editor.draft.values["title"] == "Typed during the write")
    #expect(editor.saved)
  }

  @Test func failedIdenticalPatchDoesNotRetryUntilExplicitlyRequested() async throws {
    var attempts = 0
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: nil, debounce: .milliseconds(10)
    ) { _, _ in
      attempts += 1
      throw WorkspaceError(message: "Synthetic write failure", violations: [])
    }
    editor.setValue("Keep this body", for: "body")
    for _ in 0..<100 where editor.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(attempts == 1)
    #expect(editor.failure != nil)
    #expect(!editor.saved)
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave() }
    editor.setValue("Unrelated property", for: "title")
    try await Task.sleep(for: .milliseconds(40))
    #expect(attempts == 1)
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave(retry: true) }
    #expect(attempts == 2)
    #expect(editor.draft.values["body"] == "Keep this body")
  }

  @Test func newRecordsAreCreatedByTheirFirstEditAndIgnoreUnloadedColumns() async throws {
    var patches: [WorkspaceRecord] = []
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes",
      store: nil, debounce: .milliseconds(10)
    ) { patch, _ in
      patches.append(patch)
      return patch.merging(["id": .string("created"), "updated_at": .string("revision-1")]) {
        _, new in new
      }
    }
    editor.setValue("New", for: "title")
    editor.setValue("Draft body", for: "body")
    editor.setValue("Must be retained, never submitted", for: "new_catalog_column")
    try await editor.flushAutosave()
    #expect(patches == [["title": .string("New"), "body": .string("Draft body")]])
    #expect(!editor.isNew)
    #expect(editor.draft.values["new_catalog_column"] == "Must be retained, never submitted")
  }

  @Test func durableRecoveryIsPrivateAndIsolatedByCanonicalWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("one/database.sqlite")
    let store = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: db)
    var editor: RecordEditorModel? = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: store, debounce: .seconds(60)
    ) { _, _ in
      throw WorkspaceError(message: "Synthetic conflict", violations: [])
    }
    editor!.setValue("Recover title", for: "title")
    editor!.setValue("Final body!", for: "body")
    editor!.setValue("Unavailable field value", for: "unknown")
    await #expect(throws: WorkspaceError.self) { try await editor!.flushAutosave() }
    editor = nil  // Relaunch has no live editor owning the stored variant.
    let reopened = EditorDraftStore(
      root: root.appendingPathComponent("drafts"),
      workspace: root.appendingPathComponent("one/../one/database.sqlite"))
    let saved = try #require(try reopened.load(table: "notes", recordID: "fixture"))
    #expect(saved.draft.values["body"] == "Final body!")
    #expect(saved.draft.values["unknown"] == "Unavailable field value")
    #expect(saved.failure == "Synthetic conflict")
    #expect(saved.draft.original?["updated_at"] == .string("revision-1"))
    let other = EditorDraftStore(
      root: root.appendingPathComponent("drafts"),
      workspace: root.appendingPathComponent("two/database.sqlite"))
    #expect(try other.load(table: "notes", recordID: "fixture") == nil)
    let files = try FileManager.default.contentsOfDirectory(
      at: reopened.directory,
      includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let mode =
      try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let recovered = RecordEditorModel(
      properties: properties + [["col": .string("new")]],
      original: original, table: "notes", store: reopened
    ) { _, _ in
      Issue.record("Recovery must not silently write")
      return [:]
    }
    #expect(recovered.recovery != nil)
    recovered.resumeDraft()
    #expect(recovered.draft.fields.map(\.id) == ["title", "body"])
    #expect(recovered.draft.values["title"] == "Recover title")
    #expect(recovered.failure == "Synthetic conflict")
    try recovered.discardDraft()
    #expect(try reopened.load(table: "notes", recordID: "fixture") == nil)
  }

  @Test func receiptCannotEraseDurableLaterChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var pending: [CheckedContinuation<WorkspaceRecord, any Error>] = []
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: store, debounce: .seconds(60), typingDelay: .seconds(60)
    ) { _, _ in
      try await withCheckedThrowingContinuation { pending.append($0) }
    }
    editor.setValue("Submitted", for: "body")
    let flush = Task { try await editor.flushAutosave() }
    for _ in 0..<100 where pending.isEmpty { await Task.yield() }
    editor.setValue("Dirty property", for: "title")
    pending[0].resume(
      returning: original.merging([
        "body": .string("Submitted"), "updated_at": .string("revision-2"),
      ]) { _, new in new })
    // The later edit is the next write; until its receipt it stays journaled.
    for _ in 0..<100 where pending.count < 2 { await Task.yield() }
    let saved = try #require(try store.load(table: "notes", recordID: "fixture"))
    #expect(saved.draft.patch == ["id": .string("fixture"), "title": .string("Dirty property")])
    #expect(saved.draft.original?["updated_at"] == .string("revision-2"))
    pending[1].resume(
      returning: original.merging([
        "body": .string("Submitted"), "title": .string("Dirty property"),
        "updated_at": .string("revision-3"),
      ]) { _, new in new })
    try await flush.value
    #expect(try store.load(table: "notes", recordID: "fixture") == nil)
  }

  @Test func realCorePersistsEveryFieldAndKeepsAConflictingEditWithoutAMerge() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let row = try #require(model.rows.first?.record)
    let editor = RecordEditorModel(
      properties: model.properties, original: row,
      table: context.table, store: nil, debounce: .seconds(60), typingDelay: .seconds(60)
    ) { patch, baseline in
      try await model.save(patch, original: baseline, context: context)
    }
    editor.setValue("Autosaved property", for: "title")
    editor.setValue("# Autosaved synthetic source!", for: "body")
    try await editor.flushAutosave()
    let saved = try #require(try await context.workspace.rows(table: "notes").first?.record)
    #expect(saved["body"] == .string("# Autosaved synthetic source!"))
    #expect(saved["title"] == .string("Autosaved property"))
    _ = try await context.workspace.write(
      table: "notes",
      patch: [
        "id": row["id"]!,
        "body": .string("Other client"),
      ], expectedUpdatedAt: saved["updated_at"]?.text)
    // With no host reader to merge from, a conflict keeps the draft for review.
    editor.setValue("Retain my conflicting edit", for: "body")
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave() }
    #expect(editor.draft.values["body"] == "Retain my conflicting edit")
    #expect(!editor.saved)
    #expect(
      try await context.workspace.rows(table: "notes").first?.record["body"]
        == .string("Other client"))
    await model.close()
  }

  @Test func staleRecoveryRetainsItsRevisionAndNeverSilentlyReplays() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var draft = RecordDraft(properties: properties, original: original)
    draft.values["body"] = "Closed draft"
    try store.save(
      StoredEditorDraft(
        table: "notes", recordID: "fixture", draft: draft,
        failure: nil, failedPatch: nil))
    var calls = 0
    let current = original.merging(["updated_at": .string("revision-2")]) { _, new in new }
    let editor = RecordEditorModel(
      properties: properties, original: current, table: "notes",
      store: store, debounce: .milliseconds(10)
    ) { _, baseline in
      calls += 1
      #expect(baseline?["updated_at"] == .string("revision-1"))
      throw WorkspaceError(message: "Synthetic conflict", violations: [])
    }
    editor.resumeDraft()
    try await Task.sleep(for: .milliseconds(40))
    #expect(calls == 0)
    #expect(editor.failure != nil)
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave() }
    #expect(calls == 1)
    #expect(
      try store.load(table: "notes", recordID: "fixture")?.draft.values["body"] == "Closed draft")
  }

  @Test func corruptJournalIsKeptAndCannotBeOverwrittenByANewEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let file = store.directory.appendingPathComponent(
      EditorDraftStore.key(
        table: "notes",
        recordID: "fixture") + ".json")
    let bytes = Data("unreadable synthetic recovery".utf8)
    try bytes.write(to: file)
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: store
    ) { _, _ in
      Issue.record("Unread recovery must not be replaced")
      return [:]
    }
    editor.setValue("New typing", for: "body")
    #expect(editor.failure != nil)
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    #expect(try Data(contentsOf: file) == bytes)
    #expect(editor.draft.values["body"] == "New typing")
  }

  @Test func revertingAFailedPatchRemovesObsoleteFailureAndRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: store, debounce: .seconds(60)
    ) { _, _ in
      throw WorkspaceError(message: "Invalid synthetic source", violations: [])
    }
    editor.setValue("Invalid", for: "body")
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave() }
    editor.setValue("Old", for: "body")
    try await editor.flushAutosave()
    #expect(editor.failure == nil)
    #expect(editor.saved)
    #expect(try store.load(table: "notes", recordID: "fixture") == nil)
  }

  @Test func revertingWhileAWriteIsPendingRetainsRecoveryUntilTheLatestValueIsAcknowledged()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var pending: CheckedContinuation<WorkspaceRecord, any Error>?
    var attempts = 0
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: store, debounce: .seconds(60)
    ) { patch, baseline in
      attempts += 1
      if attempts == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
      return baseline!.merging(patch) { _, new in new }.merging([
        "updated_at": .string("revision-3")
      ]) { _, new in new }
    }
    editor.setValue("Submitted body", for: "body")
    let saving = Task { try await editor.flushAutosave() }
    for _ in 0..<100 where pending == nil { await Task.yield() }
    let receipt = try #require(pending)
    editor.setValue("Old", for: "body")
    let journal = try store.load(table: "notes", recordID: "fixture")
    #expect(journal?.draft.values["body"] == "Old")
    #expect(!editor.saved)
    receipt.resume(
      returning: original.merging([
        "body": .string("Submitted body"), "updated_at": .string("revision-2"),
      ]) { _, new in new })
    try await saving.value
    #expect(attempts == 2)
    #expect(editor.draft.original?["body"] == .string("Old"))
    #expect(try store.all().isEmpty)
  }

  @Test func twoWindowsKeepIndependentDraftsAndDiscardOnlyTheirOwn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let first = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Properties must not autosave")
      return [:]
    }
    let second = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Properties must not autosave")
      return [:]
    }
    first.setValue("First window", for: "title")
    second.setValue("Second window", for: "title")
    #expect(try store.all().count == 2)
    try first.discardDraft()
    let kept = try store.all()
    #expect(kept.count == 1)
    #expect(kept.first?.draft.values["title"] == "Second window")
  }

  @Test func resumingADraftStillOpenInAnotherWindowDoesNotShareItsJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let first = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Properties must not autosave")
      return [:]
    }
    first.setValue("First window", for: "title")
    let second = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Properties must not autosave")
      return [:]
    }
    second.resumeDraft()
    second.setValue("Second window", for: "title")
    try second.discardDraft()
    #expect(try store.all().first?.draft.values["title"] == "First window")
  }

  @Test func recoveryAfterActualCommitWithoutReceiptRetainsUndoAndRequiresReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    try await workspace.indexSearch()
    let row = try await workspace.write(
      table: "notes",
      patch: [
        "title": .string("Pending receipt fixture"), "body": .string("A"),
      ])
    var held: CheckedContinuation<WorkspaceRecord, any Error>?
    let editor = RecordEditorModel(
      properties: properties, original: row, table: "notes", store: store,
      debounce: .seconds(60)
    ) { patch, baseline in
      _ = try await workspace.write(
        table: "notes", patch: patch,
        expectedUpdatedAt: baseline?["updated_at"]?.text)
      return try await withCheckedThrowingContinuation { held = $0 }
    }
    editor.setValue("B", for: "body")
    let saving = Task { try await editor.flushAutosave() }
    for _ in 0..<1000 where held == nil { await Task.yield() }
    let heldReceipt = try #require(held)
    editor.setValue("A", for: "body")
    let stored = try #require(try store.load(table: "notes", recordID: row["id"]?.text))
    #expect(stored.pendingWrite?.patch["body"] == .string("B"))
    #expect(stored.pendingWrite?.expectedUpdatedAt == row["updated_at"]?.text)
    #expect(stored.pendingWrite?.id.isEmpty == false)
    let actual = try #require(
      try await workspace.rows(table: "notes", search: "Pending receipt fixture").first?.record)
    #expect(actual["body"] == .string("B"))
    let recovered = RecordEditorModel(
      properties: properties, original: actual, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("An ambiguous recovered write must not be replayed")
      return [:]
    }
    recovered.resumeDraft()
    #expect(recovered.draft.values["body"] == "A")
    #expect(recovered.draft.original?["updated_at"] == row["updated_at"])
    #expect(recovered.failure != nil)
    #expect(!recovered.saved)
    await #expect(throws: WorkspaceError.self) { try await recovered.flushAutosave() }
    await #expect(throws: WorkspaceError.self) { try await recovered.saveAll() }
    #expect(try store.all().contains { $0.draft.values["body"] == "A" && $0.pendingWrite != nil })
    // End the simulated killed host only after verifying the actual committed
    // database and independent recovery. No receipt was delivered to that host.
    heldReceipt.resume(throwing: CancellationError())
    _ = try? await saving.value
    try await workspace.close()
  }

  @Test func newRecordWindowsKeepSeparateVariantsAndOfferBothAfterRelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let first = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) { _, _ in [:] }
    let second = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) { _, _ in [:] }
    first.setValue("New first", for: "title")
    second.setValue("New second", for: "title")
    let reopened = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) { _, _ in [:] }
    #expect(reopened.recoveryChoices.count == 2)
    #expect(
      Set(reopened.recoveryChoices.compactMap { $0.draft.values["title"] }) == [
        "New first", "New second",
      ])
    try first.discardDraft()
    #expect(try store.all().count == 1)
    #expect(try store.all().first?.draft.values["title"] == "New second")
  }

  @Test func staleResumeActionCannotReplaceTypingInAnAlreadyResumedDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var draft = RecordDraft(properties: properties, original: original)
    draft.values["title"] = "Stored draft"
    let saved = StoredEditorDraft(
      table: "notes", recordID: "fixture", draft: draft,
      failure: nil, failedPatch: nil)
    try store.save(saved)
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Properties must not autosave")
      return [:]
    }
    editor.resumeDraft(saved)
    editor.setValue("Later typing", for: "title")
    editor.resumeDraft(saved)
    #expect(editor.draft.values["title"] == "Later typing")
    #expect(try store.all().first?.draft.values["title"] == "Later typing")
  }

  @Test func pendingRecoveryCanBeKeptAndLatestRecordOpenedWithoutLosingItsJournal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var draft = RecordDraft(properties: properties, original: original)
    draft.values["title"] = "Recovered property"
    let pending = PendingEditorWrite(
      id: "synthetic-pending-write",
      patch: ["id": .string("fixture"), "body": .string("Submitted")],
      expectedUpdatedAt: "revision-1")
    let saved = StoredEditorDraft(
      table: "notes", recordID: "fixture", draft: draft,
      failure: nil, failedPatch: nil, pendingWrite: pending)
    try store.save(saved)
    let latest = original.merging([
      "body": .string("Submitted"), "updated_at": .string("revision-2"),
    ]) {
      _, new in new
    }
    let recovered = RecordEditorModel(
      properties: properties, original: latest, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Keeping a draft must not save")
      return [:]
    }
    recovered.resumeDraft()
    try recovered.keepDraft()
    #expect(try store.all().first?.draft.values["title"] == "Recovered property")
    #expect(try store.all().first?.pendingWrite?.id == "synthetic-pending-write")
    let fresh = RecordEditorModel(
      properties: properties, original: latest, table: "notes", store: store
    ) { patch, row in
      #expect(row?["updated_at"] == .string("revision-2"))
      return latest.merging(patch) { _, new in new }
    }
    fresh.openSavedRecord()
    #expect(fresh.recovery == nil)
    #expect(fresh.draft.values["body"] == "Submitted")
    #expect(try store.all().count == 1)
    fresh.setValue("Reviewed source", for: "body")
    try await fresh.flushAutosave()
    #expect(try store.all().first?.draft.values["title"] == "Recovered property")
  }

  @Test func appContainerRelocationPreservesRecoveryWithoutMixingOtherDatabases() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = root.appendingPathComponent("container-before/iris")
    let after = root.appendingPathComponent("container-after/iris")
    let first = EditorDraftStore(
      root: before.appendingPathComponent("drafts"),
      workspace: before.appendingPathComponent("local.sqlite"))
    var draft = RecordDraft(properties: properties, original: original)
    draft.values["body"] = "Retained across app update"
    try first.save(
      StoredEditorDraft(
        table: "notes", recordID: "fixture", draft: draft,
        failure: nil, failedPatch: nil))
    try FileManager.default.createDirectory(
      at: after.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: before, to: after)
    let relocated = EditorDraftStore(
      root: after.appendingPathComponent("drafts"),
      workspace: after.appendingPathComponent("local.sqlite"))
    #expect(try relocated.all().first?.draft.values["body"] == "Retained across app update")
    let other = EditorDraftStore(
      root: after.appendingPathComponent("drafts"),
      workspace: after.appendingPathComponent("replicas/other.sqlite"))
    #expect(try other.all().isEmpty)
    let external = EditorDraftStore(
      root: after.appendingPathComponent("drafts"),
      workspace: root.appendingPathComponent("external/local.sqlite"))
    #expect(try external.all().isEmpty)
  }

  #if targetEnvironment(simulator)
    // App-host setup for the UI recovery test. Never runs on a Mac or device;
    // the caller must explicitly identify its disposable simulator.
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_RECOVERY_SIMULATOR"] != nil))
    func preparePendingRecoveryUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_RECOVERY_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      let workspace = try #require(model.client)
      let rows = try await workspace.rows(table: "notes")
      var patch: WorkspaceRecord = [
        "title": .string("Pending recovery fixture"), "body": .string("Recovered body to keep"),
      ]
      if let row = rows.first(where: { $0.record["title"] == patch["title"] }) {
        patch["id"] = row.record["id"]
      }
      let original = try await workspace.write(table: "notes", patch: patch)
      let id = try #require(original["id"]?.text)
      var draft = RecordDraft(properties: model.properties, original: original)
      draft.values["title"] = "Recovered property to keep"
      let pending = PendingEditorWrite(
        id: UUID().uuidString,
        patch: ["id": .string(id), "body": .string("Submitted body on disk")],
        expectedUpdatedAt: original["updated_at"]?.text)
      _ = try await workspace.write(
        table: "notes", patch: pending.patch, expectedUpdatedAt: pending.expectedUpdatedAt)
      let url = try WorkspaceModel.localURL()
      let store = EditorDraftStore(
        root: url.deletingLastPathComponent().appendingPathComponent("drafts"), workspace: url)
      for saved in try store.all() where saved.recordID == id {
        try store.remove(table: saved.table, recordID: id, draftID: saved.id)
      }
      try store.save(
        StoredEditorDraft(
          table: "notes", recordID: id, draft: draft,
          failure: nil, failedPatch: nil, pendingWrite: pending))
      #expect(try store.all().contains { $0.recordID == id && $0.pendingWrite != nil })
      try await workspace.close()
    }
  #endif
}
