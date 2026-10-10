import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct UndoTests {
  let fields: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
  ]
  let original: WorkspaceRecord = [
    "id": .string("record"), "title": .string("Saved title"),
    "body": .string("Saved body"), "updated_at": .string("revision-2"), "deleted_at": .null,
  ]
  let action = CoreUndoAction(
    receiptId: String(repeating: "a", count: 32), table: "notes", rowId: "record", kind: .edit)

  @Test func undoPreservesNewerFieldsAndPausesDurablyUntilExplicitSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"), workspace: root.appendingPathComponent("db"))
    var writes: [(WorkspaceRecord, WorkspaceRecord?)] = []
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: store,
      debounce: .milliseconds(20)
    ) { patch, baseline in
      writes.append((patch, baseline))
      return baseline!.merging(patch) { _, value in value }.merging([
        "updated_at": .string("revision-4")
      ]) { _, value in value }
    }
    editor.setValue("Newer draft", for: "body")
    editor.setValue("Unknown retained", for: "unavailable")
    var held: CheckedContinuation<WorkspaceRecord, any Error>?
    let undo = Task {
      try await editor.performUndo(action) {
        try await withCheckedThrowingContinuation { held = $0 }
      }
    }
    for _ in 0..<100 where held == nil { await Task.yield() }
    #expect(held != nil && editor.saving)
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave() }
    editor.setValue("Final newer draft", for: "body")
    let savedPending = try #require(try store.all().first)
    #expect(savedPending.undoUnconfirmed == true)
    #expect(savedPending.draft.values["body"] == "Final newer draft")
    let restored = original.merging([
      "title": .string("Before title"), "body": .string("Before body"),
      "updated_at": .string("revision-3"),
    ]) { _, value in value }
    held?.resume(returning: restored)
    try await undo.value
    #expect(editor.draft.values["title"] == "Before title")
    #expect(editor.draft.values["body"] == "Final newer draft")
    #expect(editor.draft.values["unavailable"] == "Unknown retained")
    #expect(editor.draft.original == restored && editor.autosavePaused)
    try await Task.sleep(for: .milliseconds(60))
    #expect(writes.isEmpty)
    let recovered = RecordEditorModel(
      properties: fields, original: restored, table: "notes", store: store,
      debounce: .milliseconds(10)
    ) { _, _ in
      Issue.record("Recovered draft must not autosave")
      return [:]
    }
    recovered.resumeDraft()
    #expect(recovered.autosavePaused)
    recovered.setValue("Still held after relaunch", for: "body")
    try await Task.sleep(for: .milliseconds(40))
    try await editor.saveAll()
    #expect(writes.count == 1)
    #expect(writes.first?.1?["updated_at"] == .string("revision-3"))
    #expect(writes.first?.0 == ["id": .string("record"), "body": .string("Final newer draft")])
  }

  @Test func failedUndoKeepsDraftAndPausedAutosaveAndUnknownOutcomeRequiresReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"), workspace: root.appendingPathComponent("db"))
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: store,
      debounce: .milliseconds(10)
    ) { _, _ in
      Issue.record("Undo failure must not flush or retry a draft")
      return [:]
    }
    editor.setValue("Retained", for: "body")
    do {
      try await editor.performUndo(action) {
        let pending = try #require(try store.all().first)
        let restored = RecordEditorModel(
          properties: fields, original: original, table: "notes", store: nil, recovered: pending
        ) { _, _ in [:] }
        restored.resumeDraft()
        #expect(restored.needsReview)
        await #expect(throws: WorkspaceError.self) { try await restored.saveAll() }
        throw WorkspaceError(message: "Rejected inverse", violations: [])
      }
      Issue.record("Undo must reject")
    } catch is WorkspaceError {}
    editor.setValue("Retained after failure", for: "body")
    try await Task.sleep(for: .milliseconds(40))
    #expect(editor.autosavePaused && editor.failure != nil)
    #expect(editor.draft.original == original)
    #expect(try store.all().first?.draft.values["body"] == "Retained after failure")
  }

  @Test func tombstoneRequiresSeparateRestoreAndOtherRecordDraftIsUntouched() async throws {
    var patches: [WorkspaceRecord] = []
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: nil,
      debounce: .milliseconds(10)
    ) { patch, baseline in
      patches.append(patch)
      return baseline!.merging(patch) { _, value in value }.merging([
        "updated_at": .string("restored")
      ]) { _, value in value }
    }
    editor.setValue("Keep this draft", for: "body")
    let tombstone = original.merging([
      "deleted_at": .string("timestamp"), "updated_at": .string("trashed"),
    ]) { _, value in value }
    try await editor.performUndo(action) { tombstone }
    #expect(editor.isTrashed && editor.autosavePaused)
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    await #expect(throws: WorkspaceError.self) { try await editor.flushAutosave(retry: true) }
    try await editor.saveAll(["id": .string("record"), "deleted_at": .null])
    #expect(!editor.isTrashed && editor.autosavePaused)
    #expect(editor.draft.values["body"] == "Keep this draft")
    #expect(patches == [["id": .string("record"), "deleted_at": .null]])
    let baseline = editor.draft.original
    let other = CoreUndoAction(
      receiptId: action.receiptId, table: "other", rowId: "record", kind: .edit)
    try await editor.performUndo(other) { ["id": .string("record"), "body": .string("Other row")] }
    #expect(editor.draft.original == baseline && editor.draft.values["body"] == "Keep this draft")
  }

  @Test func pendingSaveAndSupersededEditorCannotBeUndoneOrReconciled() async throws {
    var pending: CheckedContinuation<WorkspaceRecord, any Error>?
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: nil, debounce: .seconds(60)
    ) { _, _ in
      try await withCheckedThrowingContinuation { pending = $0 }
    }
    editor.setValue("Pending body", for: "body")
    let saving = Task { try await editor.flushAutosave() }
    for _ in 0..<100 where pending == nil { await Task.yield() }
    await #expect(throws: WorkspaceError.self) {
      try await editor.performUndo(action) {
        Issue.record("Undo cannot run during a save")
        return original
      }
    }
    pending?.resume(
      returning: original.merging(["body": .string("Pending body")]) { _, value in value })
    try await saving.value
    let baseline = editor.draft.original
    var current = true
    await #expect(throws: WorkspaceError.self) {
      try await editor.performUndo(
        action, isCurrent: { current },
        operation: {
          current = false
          return original
        })
    }
    #expect(editor.draft.original == baseline)
    #expect(editor.autosavePaused && editor.failure != nil)
  }

  @Test func unconfirmedRecoveryCannotStartAnotherUndo() async throws {
    let pending = StoredEditorDraft(
      table: "notes", recordID: "record",
      draft: RecordDraft(properties: fields, original: original), failure: nil, failedPatch: nil,
      autosavePaused: true, undoUnconfirmed: true)
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: nil, recovered: pending
    ) { _, _ in [:] }
    editor.resumeDraft()
    await #expect(throws: WorkspaceError.self) {
      try await editor.performUndo(action) {
        Issue.record("Review the unconfirmed outcome first")
        return original
      }
    }
    #expect(editor.needsReview)
  }

  @Test func journalFailureAfterLiveSnapshotPreventsInverseAndKeepsLatestText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"), workspace: root.appendingPathComponent("db"))
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: store
    ) { _, _ in [:] }
    var called = false
    await #expect(throws: (any Error).self) {
      try await editor.performUndo(
        action,
        collect: {
          // Keep the prior journal, but make subsequent atomic writes fail.
          try FileManager.default.moveItem(
            at: store.directory, to: root.appendingPathComponent("kept-journal"))
          try Data("unwritable-directory-fixture".utf8).write(to: store.directory)
          editor.setValue("Last live keystroke!", for: "body")
        },
        operation: {
          called = true
          return original
        })
    }
    #expect(!called)
    #expect(editor.draft.values["body"] == "Last live keystroke!")
    #expect(editor.failure != nil && editor.autosavePaused)
  }

  @Test func liveSnapshotIsCollectedAfterPausingAndBeforeUndo() async throws {
    let editor = RecordEditorModel(
      properties: fields, original: original, table: "notes", store: nil, debounce: .milliseconds(1)
    ) { _, _ in
      Issue.record("Collecting the live document must not flush it")
      return [:]
    }
    var collected = false
    try await editor.performUndo(
      action,
      collect: {
        #expect(editor.saving && editor.autosavePaused)
        editor.setValue("Last live keystroke!", for: "body")
        collected = true
        await Task.yield()
      },
      operation: {
        #expect(collected)
        return original.merging(["body": .string("Before"), "updated_at": .string("revision-3")]) {
          _, value in value
        }
      })
    #expect(editor.draft.values["body"] == "Last live keystroke!")
    #expect(editor.draft.original?["body"] == .string("Before"))
    #expect(editor.autosavePaused)
    try await Task.sleep(for: .milliseconds(20))
  }

  @Test func undoReconciliationPreservesLoadedImmutableFieldsAndUnknownDraftKeys() {
    let properties: [WorkspaceRecord] = [
      ["col": .string("code"), "type": .string("text"), "immutable": .bool(true)],
      ["col": .string("enabled"), "type": .string("bool")],
    ]
    var draft = RecordDraft(properties: properties, original: nil)
    draft.values["code"] = "stable-code"
    draft.values["enabled"] = "true"
    let created: WorkspaceRecord = [
      "id": .string("new"), "code": .string("stable-code"), "enabled": .number(1),
    ]
    draft.acknowledge(created, sent: draft.patch)
    draft.values["unknown"] = "Keep this"
    draft.reconcileUndo(
      created.merging(["enabled": .number(0), "deleted_at": .string("timestamp")]) { _, value in
        value
      })
    #expect(draft.fields.map(\.id) == ["code", "enabled"])
    #expect(draft.values["code"] == "stable-code")
    #expect(draft.values["enabled"] == "false")
    #expect(draft.values["unknown"] == "Keep this")
    #expect(draft.patch == ["id": .string("new")])
  }

  @Test func realCoreRejectsExternalRevisionAndReopenHasNoReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("fixture.sqlite").path
    let first = try NativeWorkspace(path: path)
    try await first.createSample()
    try await first.indexSearch()
    let row = try await first.write(table: "notes", patch: ["title": .string("Initial")])
    let action = try #require(try await first.undoStatus().action)
    let other = try NativeWorkspace(path: path)
    _ = try await other.write(
      table: "notes", patch: ["id": row["id"]!, "title": .string("New external revision")])
    await #expect(throws: WorkspaceError.self) { try await first.undo(receiptID: action.receiptId) }
    #expect(try await first.undoStatus().action == action)
    #expect(try await first.rows(table: "notes", search: "external").count == 1)
    try await other.close()
    try await first.close()
    let reopened = try NativeWorkspace(path: path)
    #expect(try await reopened.undoStatus().action == nil)
    #expect(try await reopened.rows(table: "notes", search: "external").count == 1)
    try await reopened.close()
  }

  @Test(arguments: [CoreUndoKind.create, .edit, .trash, .restore])
  func realCoreUndoUsesDisplayedReceiptAndFreshValidatedWrites(kind: CoreUndoKind) async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let created = try await workspace.write(
      table: "notes", patch: ["title": .string("Undo fixture"), "body": .string("Before")])
    let id = try #require(created["id"])
    if kind == .restore {
      _ = try await workspace.write(table: "notes", patch: ["id": id, "deleted_at": .bool(true)])
    }
    if kind != .create {
      let patch: WorkspaceRecord =
        kind == .edit
        ? ["id": id, "body": .string("After")]
        : ["id": id, "deleted_at": kind == .trash ? .bool(true) : .null]
      _ = try await workspace.write(table: "notes", patch: patch)
    }
    let action = try #require(try await workspace.undoStatus().action)
    #expect(action.kind == kind && action.table == "notes" && action.rowId == id.text)
    let result = try await workspace.undo(receiptID: action.receiptId)
    #expect(result["body"] == .string("Before"))
    #expect((result["deleted_at"] != .null) == (kind == .create || kind == .restore))
    #expect((try await workspace.undoStatus().action == nil) == (kind == .create))
    await #expect(throws: WorkspaceError.self) {
      try await workspace.undo(receiptID: action.receiptId)
    }
    try await workspace.close()
  }
}

@MainActor
struct WorkspaceUndoTests {
  @Test func displayedReceiptIsRequiredAndSuccessfulUndoRefreshesRowsAndStatus() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let created = try await model.save(
      ["title": .string("Model Undo fixture")], original: nil, context: context)
    let first = try #require(model.undoAction)
    #expect(first.kind == .create)
    let changed = try await model.save(
      ["id": created["id"]!, "title": .string("Changed")], original: created, context: context)
    let shown = try #require(model.undoAction)
    await #expect(throws: WorkspaceError.self) { try await model.undo(first, context: context) }
    #expect(model.undoAction == shown)
    let receipt = try await model.undo(shown, context: context)
    #expect(receipt["title"] == .string("Model Undo fixture"))
    #expect(receipt["updated_at"] != changed["updated_at"])
    #expect(model.rows.contains { $0.record["title"] == .string("Model Undo fixture") })
    #expect(model.undoAction == first)
    _ = try await model.undo(first, context: context)
    #expect(model.undoAction == nil)
    await model.close()
  }

  @Test func rejectedInverseKeepsCoreActionAndSavedViewsJoinTheUndoStack() async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let row = try await model.save(["title": .string("Before")], original: nil, context: context)
    _ = try await model.save(
      ["id": row["id"]!, "title": .string("After")], original: row, context: context)
    let shown = try #require(model.undoAction)
    runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE catalog_properties SET pattern='^After$' WHERE tbl='notes' AND col='title'\")"
    )
    #expect(runtime.context.exception == nil)
    await #expect(throws: WorkspaceError.self) { try await model.undo(shown, context: context) }
    #expect(model.undoAction == shown)
    #expect(try await client.undoStatus().action == shown)
    try await model.saveCurrentView(name: "Undo test view", update: false, context: context)
    let viewUndo = try #require(model.undoAction)
    #expect(viewUndo.table == "views")
    _ = try await model.undo(viewUndo, context: context)
    #expect(model.appliedView == nil)
    #expect(model.savedViews.isEmpty)
    #expect(model.undoAction == shown)
    await model.close()
  }

  @Test(arguments: ["undo", "rows"])
  func pendingUndoBlocksWritesAndLateReceiptCannotUpdateReplacementWorkspace(phase: String)
    async throws
  {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    _ = try await model.save(["title": .string("Old workspace")], original: nil, context: context)
    let shown = try #require(model.undoAction)
    runtime.context.evaluateScript(
      "var originalRequest = IrisNative.request; var heldUndo = null; IrisNative.request = (id,method,args) => { if(method === '\(phase)') heldUndo = [id,method,args]; else originalRequest(id,method,args); };"
    )
    let task = Task { try await model.undo(shown, context: context) }
    for _ in 0..<100 where runtime.context.evaluateScript("heldUndo === null")?.toBool() == true {
      await Task.yield()
    }
    #expect(model.undoing)
    await #expect(throws: WorkspaceError.self) {
      try await model.save(["title": .string("Blocked")], original: nil, context: context)
    }
    await #expect(throws: WorkspaceError.self) {
      try await model.saveCurrentView(name: "Blocked", update: false, context: context)
    }
    let replacement = try NativeWorkspace(path: ":memory:")
    try await replacement.createSample()
    model.client = replacement
    await model.reload()
    let replacementRows = model.rows
    runtime.context.evaluateScript(
      "IrisNative.request = originalRequest; originalRequest(...heldUndo);")
    await #expect(throws: WorkspaceError.self) { try await task.value }
    #expect(model.client === replacement && model.undoAction == nil && !model.undoing)
    #expect(model.rows == replacementRows)
    await #expect(throws: WorkspaceError.self) { try await model.undo(shown, context: context) }
    try await client.close()
    await model.close()
  }
}
