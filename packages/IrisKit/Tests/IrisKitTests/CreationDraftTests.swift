import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct CreationDraftTests {
  private let fields: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("status"), "type": .string("select"), "default_value": .string("Draft")],
    ["col": .string("body"), "type": .string("markdown")],
  ]

  @Test(arguments: ["untouched", "same empty", "type then clear"])
  func realCoreDefaultsApplyOnlyToUntouchedNewFields(_ edit: String) async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let properties = try await workspace.catalog().properties.filter {
      $0["tbl"] == .string("notes")
    }
    let before = runtime.context.evaluateScript("IrisSql.all('SELECT total_changes() AS n')[0].n")!
      .toInt32()
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: nil
    ) {
      patch, baseline in
      #expect(baseline == nil)
      return try await workspace.write(table: "notes", patch: patch)
    }
    editor.setValue("Created", for: "title")
    if edit == "type then clear" { editor.setValue("Ready", for: "status") }
    if edit != "untouched" { editor.setValue("", for: "status", explicit: true) }
    #expect(editor.draft.patch["status"] == (edit == "untouched" ? nil : .null))
    #expect(
      runtime.context.evaluateScript("IrisSql.all('SELECT total_changes() AS n')[0].n")!.toInt32()
        == before)
    // The first autosave creates the row; untouched fields still take core defaults.
    try await editor.flushAutosave()
    let saved = try #require(editor.draft.original)
    #expect(saved["status"] == (edit == "untouched" ? .string("Draft") : .null))
    #expect(editor.draft.values["status"] == (edit == "untouched" ? "Draft" : ""))
    #expect(try await workspace.rows(table: "notes").count == 2)
    #expect(!editor.dirty)
    try await workspace.close()
  }

  @Test(arguments: [false, true])
  func emptyCoreDefaultStaysCleanUnlessClearedWhileSaveWasPending(_ clear: Bool) async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE catalog_properties SET default_value='' WHERE tbl='notes' AND col='body'\")"
    )
    try #require(runtime.context.exception == nil)
    var pending: CheckedContinuation<Void, Never>?
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      patch, _ in
      let receipt = try await workspace.write(table: "notes", patch: patch)
      await withCheckedContinuation { pending = $0 }
      return receipt
    }
    editor.setValue("Created", for: "title")
    let saving = Task { try await editor.saveAll() }
    for _ in 0..<1000 where pending == nil { await Task.yield() }
    let release = try #require(pending)
    if clear { editor.setValue("", for: "body", explicit: true) }
    release.resume()
    try await saving.value
    let id = try #require(editor.draft.original?["id"])
    #expect(editor.draft.original?["body"] == .string(""))
    #expect(editor.draft.patch == (clear ? ["id": id, "body": .null] : ["id": id]))
    #expect(editor.dirty == clear)
    try await workspace.close()
  }

  @Test func explicitEmptyIntentSurvivesRecoveryWithoutChangingLegacyJournalMeaning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("fixture.sqlite"))
    let legacy = try JSONDecoder().decode(
      RecordDraft.self,
      from: Data(
        #"""
        {"values":{"title":"Legacy","status":""},
         "fields":[{"property":{"col":"title","type":"text"}},{"property":{"col":"status","type":"select"}}],
         "initial":{"title":"","status":""}}
        """#.utf8))
    #expect(legacy.patch == ["title": .string("Legacy")])
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in
      Issue.record("Typing or recovering must not write")
      return [:]
    }
    editor.setValue("", for: "status", explicit: true)
    #expect(editor.dirty)
    let saved = try #require(try store.load(table: "notes", recordID: nil))
    #expect(saved.recordID == nil && saved.draft.original == nil)
    #expect(saved.draft.patch == ["status": .null])
    let reopened = RecordEditorModel(
      properties: fields, original: nil, table: "notes", store: store, recovered: saved
    ) { _, _ in
      Issue.record("Recovery must not write")
      return [:]
    }
    reopened.resumeDraft()
    #expect(reopened.isNew && reopened.dirty)
    #expect(reopened.draft.patch == ["status": .null])
  }

  @Test func creationReceiptKeepsAnExplicitClearMadeWhileTheWriteWasPending() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    var pending: CheckedContinuation<Void, Never>?
    var calls: [WorkspaceRecord] = []
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      patch, baseline in
      calls.append(patch)
      let row = try await workspace.write(
        table: "notes", patch: patch, expectedUpdatedAt: baseline?["updated_at"]?.text)
      if calls.count == 1 { await withCheckedContinuation { pending = $0 } }
      return row
    }
    editor.setValue("Created", for: "title")
    var finished = false
    let saving = Task {
      defer { finished = true }
      try await editor.saveAll()
    }
    for _ in 0..<1000 where pending == nil && !finished { await Task.yield() }
    let release = try #require(pending)
    editor.setValue("", for: "status", explicit: true)
    release.resume()
    try await saving.value
    let id = try #require(editor.draft.original?["id"])
    // The receipt keeps the clear made during the write; autosave sends it next.
    try await editor.flushAutosave()
    #expect(calls == [["title": .string("Created")], ["id": id, "status": .null]])
    #expect(editor.draft.original?["status"] == .null)
    #expect(!editor.dirty)
    try await workspace.close()
  }

  @Test func explicitCreationClearSurvivesUndoReconciliationButExistingNoOpStaysClean() throws {
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      _, _ in [:]
    }
    editor.setValue("", for: "status", explicit: true)
    var draft = editor.draft
    draft.reconcileUndo([
      "id": .string("created"), "status": .string("Draft"), "deleted_at": .string("trashed"),
    ])
    #expect(draft.values["status"] == "")
    #expect(draft.patch == ["id": .string("created"), "status": .null])
    let existing = RecordEditorModel(
      properties: fields, original: ["id": .string("existing"), "status": .null], table: "notes",
      store: nil
    ) { _, _ in
      Issue.record("No-op must not write")
      return [:]
    }
    existing.setValue("", for: "status", explicit: true)
    #expect(!existing.dirty)
    existing.setValue("Ready", for: "status")
    existing.setValue("", for: "status")
    #expect(!existing.dirty && existing.draft.patch == ["id": .string("existing")])
  }

  @Test func canonicallyEquivalentTypingStillChangesTheExactCreationValue() {
    let editor = RecordEditorModel(
      properties: fields, original: nil, table: "notes", store: nil
    ) { _, _ in
      Issue.record("Typing must not write")
      return [:]
    }
    editor.setValue("café", for: "title")
    editor.setValue("cafe\u{301}", for: "title")
    #expect(Data(editor.draft.values["title"]!.utf8) == Data([99, 97, 102, 101, 204, 129]))
  }

  @Test func collectingAnUntouchedMarkdownSnapshotDoesNotOverrideItsCoreDefault() async throws {
    // A long pause keeps autosave out of this check of the draft's patch.
    let editor = RecordEditorModel(
      properties: fields, original: nil, table: "notes", store: nil, debounce: .seconds(60)
    ) {
      _, _ in
      Issue.record("Collecting a snapshot must not write")
      return [:]
    }
    let session = MarkdownEditorSession(value: "", label: "Body")
    session.onChange = { editor.setValue($0, for: "body") }
    session.snapshot = { [unowned session] _ in session.document }
    try await session.collectSnapshot(lock: true)
    #expect(editor.draft.patch.isEmpty && !editor.dirty)
    // An explicit source edit remains explicit after it is cleared again.
    session.editSource("Typed")
    session.editSource("")
    #expect(editor.draft.patch == ["body": .null])
    // Leave no autosave scheduled for after this test.
    try editor.keepDraft()
  }
}
