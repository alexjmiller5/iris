import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct RejectedDraftTests {
  private let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
  ]
  private let original: WorkspaceRecord = [
    "id": .string("row"), "title": .string("Current title"),
    "body": .string("Current body"), "updated_at": .string("revision-2"),
    "deleted_at": .null,
  ]

  @Test func reviewKeepsFreshRevisionAndOnlyCopiesCurrentlyEditableFields() throws {
    let fields =
      properties + [
        ["col": .string("locked"), "immutable": .bool(true)],
        ["col": .string("computed"), "derived_by": .string("rule")],
        ["col": .string("retired"), "deprecated": .bool(true)],
        ["col": .string("flag"), "type": .string("bool")],
        ["col": .string("nullable"), "type": .string("text")],
        ["col": .string("tags"), "type": .string("multi_select")],
      ]
      + ["id", "created_at", "updated_at", "deleted_at", "hub_at"].map {
        ["col": .string($0), "type": .string("text")]
      }
    let baseline = original.merging(["nullable": .string("Clear this")]) { _, next in next }
    let editor = RecordEditorModel(
      properties: fields, original: baseline, table: "items", store: nil
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    try editor.installRejectedDraft(submitted: [
      "id": .string("row"), "title": .string("Rejected title"),
      "updated_at": .string("revision-1"), "created_at": .string("old"),
      "deleted_at": .string("old"), "hub_at": .string("old"),
      "locked": .string("old"), "computed": .string("old"),
      "retired": .string("old"), "unknown": .string("old"),
      "flag": .number(0), "nullable": .null,
      "tags": .string("[ \"Unknown\", \"e\u{301}\" ]"),
    ])
    #expect(editor.draft.original == baseline)
    #expect(editor.draft.values["title"] == "Rejected title")
    #expect(editor.draft.values["body"] == "Current body")
    #expect(editor.draft.values["flag"] == "false")
    #expect(editor.draft.values["nullable"] == "")
    #expect(editor.draft.values["tags"] == "[ \"Unknown\", \"e\u{301}\" ]")
    #expect(editor.draft.unknownValues.isEmpty)
    #expect(Set(editor.draft.patch.keys) == ["id", "title", "flag", "tags", "nullable"])
    #expect(editor.autosavePaused)
    #expect(!editor.needsReview)
  }

  @Test func reviewAndLaterTypingCannotAutosaveButExplicitSaveUsesFreshBaseline() async throws {
    var calls: [(WorkspaceRecord, WorkspaceRecord?)] = []
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: nil,
      debounce: .milliseconds(1)
    ) { patch, baseline in
      calls.append((patch, baseline))
      return baseline!.merging(patch) { _, next in next }.merging([
        "updated_at": .string("revision-3")
      ]) { _, next in next }
    }
    try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    editor.setValue("Corrected body", for: "body")
    try await Task.sleep(for: .milliseconds(30))
    #expect(calls.isEmpty)
    await #expect(throws: WorkspaceError.self) { try await editor.flushMarkdown() }
    #expect(calls.isEmpty)
    try await editor.saveAll()
    #expect(calls.count == 1)
    #expect(calls.first?.0 == ["id": .string("row"), "body": .string("Corrected body")])
    #expect(calls.first?.1?["updated_at"] == .string("revision-2"))
    #expect(!editor.autosavePaused && !editor.dirty)
  }

  @Test func reviewPersistsADistinctPausedJournalAndNeverAdoptsAnExistingRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    var oldDraft = RecordDraft(
      properties: properties,
      original: original.merging([
        "updated_at": .string("revision-1")
      ]) { _, next in next })
    oldDraft.values["body"] = "Older unsaved body"
    let old = StoredEditorDraft(
      id: "old-journal", table: "items", recordID: "row", draft: oldDraft,
      failure: nil, failedPatch: nil)
    try store.save(old)
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: store
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    #expect(editor.recovery != nil)
    try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    let stored = try store.all()
    #expect(stored.count == 2)
    let kept = try #require(stored.first { $0.id == "old-journal" })
    #expect(kept.draft.original?["updated_at"] == .string("revision-1"))
    #expect(kept.draft.values["body"] == "Older unsaved body")
    let review = try #require(stored.first { $0.id != "old-journal" })
    #expect(review.autosavePaused == true)
    #expect(review.draft.original?["updated_at"] == .string("revision-2"))
    #expect(review.draft.values["body"] == "Review")
    #expect(editor.recovery == nil)
    let reopened = RecordEditorModel(
      properties: properties, original: original, table: "items", store: store, recovered: review
    ) { _, _ in
      Issue.record("Recovery must not write")
      return [:]
    }
    reopened.resumeDraft()
    #expect(reopened.autosavePaused)
    #expect(!reopened.needsReview)
    #expect(reopened.draft.values["body"] == "Review")
    #expect(reopened.draft.original?["updated_at"] == .string("revision-2"))
  }

  @Test func journalFailurePreventsReviewPublication() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: store
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("blocked".utf8).write(to: store.directory)
    var published = false
    do {
      try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
      published = true
    } catch {}
    #expect(!published)
    #expect(try Data(contentsOf: store.directory) == Data("blocked".utf8))
    #expect(editor.draft.original == original)
    #expect(editor.draft.values["body"] == "Current body")
    #expect(!editor.autosavePaused)
  }

  @Test func unreadableRecoveryIsNeverOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let path = store.directory.appendingPathComponent("invalid.json")
    try Data("invalid".utf8).write(to: path)
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: store
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    }
    #expect(try Data(contentsOf: path) == Data("invalid".utf8))
    #expect(editor.draft.values["body"] == "Current body")
  }

  @Test(arguments: ["other", "e\u{301}"])
  func reviewCannotInstallOntoAnotherOpaqueRecord(_ wrong: String) throws {
    let baseline = original.merging(["id": .string("\u{e9}")]) { _, next in next }
    let editor = RecordEditorModel(
      properties: properties, original: baseline, table: "items", store: nil
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try editor.installRejectedDraft(submitted: ["id": .string(wrong), "body": .string("Review")])
    }
    #expect(editor.draft.values["body"] == "Current body")
  }

  @Test func reviewCannotOverwriteAnAlreadyDirtyEditor() throws {
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: nil
    ) { _, _ in
      Issue.record("Review must not write")
      return [:]
    }
    editor.setValue("Current unsaved title", for: "title")
    #expect(throws: WorkspaceError.self) {
      try editor.installRejectedDraft(submitted: ["id": .string("row"), "title": .string("Review")])
    }
    #expect(editor.draft.values["title"] == "Current unsaved title")
  }

  @Test func reviewCannotReplaceAnInFlightSaveOrCreateAMissingRecord() async throws {
    var pending: CheckedContinuation<WorkspaceRecord, any Error>?
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "items", store: nil
    ) { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
    let saving = Task {
      try await editor.saveAll(["id": .string("row"), "deleted_at": .bool(true)])
    }
    while pending == nil { await Task.yield() }
    #expect(throws: WorkspaceError.self) {
      try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    }
    #expect(editor.draft.values["body"] == "Current body")
    pending?.resume(
      returning: original.merging(["deleted_at": .string("deleted")]) { _, next in next })
    try await saving.value
    let missing = RecordEditorModel(
      properties: properties, original: nil, table: "items", store: nil
    ) { _, _ in
      Issue.record("Review must not create a record")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try missing.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    }
    #expect(missing.draft.original == nil)
  }

  @Test func failedCorrectionKeepsPausedReviewAndRestoreKeepsRawValues() async throws {
    var patches: [WorkspaceRecord] = []
    let tombstone = original.merging(["deleted_at": .string("deleted")]) { _, next in next }
    let editor = RecordEditorModel(
      properties: properties, original: tombstone, table: "items", store: nil
    ) { patch, baseline in
      patches.append(patch)
      if patch["deleted_at"] == nil {
        throw WorkspaceError(message: "Synthetic rejection", violations: [])
      }
      return baseline!.merging(patch) { _, next in next }
    }
    try editor.installRejectedDraft(submitted: ["id": .string("row"), "body": .string("Review")])
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    #expect(patches.isEmpty)
    try await editor.saveAll(["id": .string("row"), "deleted_at": .null])
    #expect(!editor.isTrashed && editor.autosavePaused)
    #expect(editor.draft.values["body"] == "Review")
    #expect(patches == [["id": .string("row"), "deleted_at": .null]])
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    #expect(editor.draft.values["body"] == "Review")
    #expect(editor.autosavePaused)
  }

  @Test(arguments: [false, true])
  func realCoreReviewUsesFreshRevisionAndNeverClearsDurableRejection(_ newerEdit: Bool) async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("workspace.sqlite")
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: path.path, runtime: runtime)
    try await workspace.createSample()
    _ = try await workspace.status()
    runtime.context.evaluateScript(
      #"""
      const row = LifeSql.all('SELECT * FROM notes ORDER BY id LIMIT 1', [])[0];
      row.body = 'Rejected body';
      LifeSql.run('INSERT INTO _core_rejected(tbl,row_id,row,errors) VALUES (?,?,?,?)',
        ['notes', row.id, JSON.stringify(row), JSON.stringify([{id:row.id,message:'Rejected'}])]);
      """#)
    #expect(runtime.context.exception == nil)
    let entry = try #require(try await workspace.rejections().rejections.first)
    let before = try #require(try await workspace.rows(table: "notes").first?.record)
    let current = try await workspace.write(
      table: "notes", patch: ["id": before["id"]!, "body": .string("Newer local body")],
      expectedUpdatedAt: before["updated_at"]?.text)
    let fields = try await workspace.catalog().properties.filter { $0["tbl"] == .string("notes") }
    let store = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: path)
    let editor = RecordEditorModel(
      properties: fields, original: current, table: "notes", store: store
    ) { patch, baseline in
      try await workspace.write(
        table: "notes", patch: patch, expectedUpdatedAt: baseline?["updated_at"]?.text)
    }
    try editor.installRejectedDraft(submitted: entry.submitted)
    #expect(editor.draft.original?["updated_at"] == current["updated_at"])
    #expect(editor.draft.values["body"] == "Rejected body")
    #expect(
      try await workspace.rows(table: "notes").first?.record["body"] == .string("Newer local body"))
    if newerEdit {
      _ = try await workspace.write(
        table: "notes", patch: ["id": before["id"]!, "body": .string("Another editor")],
        expectedUpdatedAt: current["updated_at"]?.text)
      await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
      #expect(editor.autosavePaused)
      #expect(editor.draft.values["body"] == "Rejected body")
    } else {
      editor.setValue("Corrected body", for: "body")
      try await editor.saveAll()
      #expect(!editor.autosavePaused)
    }
    #expect(try await workspace.status().rejected == 1)
    try await workspace.close()
    let reopened = try NativeWorkspace(path: path.path)
    #expect(try await reopened.status().rejected == 1)
    #expect(
      try await reopened.rejections().rejections.first?.submitted["body"]
        == .string("Rejected body"))
    let row = try #require(try await reopened.rows(table: "notes").first?.record)
    #expect(row["body"] == .string(newerEdit ? "Another editor" : "Corrected body"))
    if newerEdit {
      let saved = try #require(try store.load(table: "notes", recordID: entry.rowID))
      #expect(saved.autosavePaused == true)
      #expect(saved.draft.values["body"] == "Rejected body")
      #expect(saved.draft.original?["updated_at"] == current["updated_at"])
    }
    try await reopened.close()
  }
}
