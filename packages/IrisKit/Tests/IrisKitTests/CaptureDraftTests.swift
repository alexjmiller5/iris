import Foundation
import Testing

@testable import IrisKit

@MainActor struct CaptureDraftTests {
  private let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
    ["col": .string("qty"), "type": .string("int")],
    ["col": .string("retired"), "type": .string("text"), "deprecated": .bool(true)],
  ]

  @Test func captureIsRecoverableUntilItsFirstAutosaveCreatesOneRealRow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let fields = try await workspace.catalog().properties.filter { $0["tbl"] == .string("notes") }
    let before = try await workspace.rows(table: "notes")
    let id = UUID()
    let text = " # Captured\n\ncafé and cafe\u{301}\n"
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    {
      patch, baseline in
      #expect(baseline == nil)
      return try await workspace.write(table: "notes", patch: patch)
    }
    try editor.installCaptureDraft(id: id, text: text, column: "body")
    #expect(try await workspace.rows(table: "notes").map(\.record) == before.map(\.record))
    editor.setValue("Synthetic capture", for: "title")
    try editor.installCaptureDraft(id: id, text: text, column: "body")
    let journals = try store.all()
    #expect(journals.count == 1)
    let journal = try #require(journals.first)
    #expect(journal.captureID == id && journal.recordID == nil)
    #expect(Data(journal.draft.values["body"]!.utf8) == Data(text.utf8))
    #expect(journal.draft.values["title"] == "Synthetic capture")
    try await editor.flushAutosave()
    try editor.installCaptureDraft(id: id, text: text, column: "body")
    try await editor.flushAutosave()
    let after = try await workspace.rows(table: "notes")
    #expect(after.count == before.count + 1)
    #expect(
      after.first { $0.record["title"] == .string("Synthetic capture") }?.record["body"]
        == .string(text))
    #expect(try store.all().isEmpty)
    try await workspace.close()
  }

  @Test func redeliveryAfterRelaunchKeepsEditedJournalAndItsIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let id = UUID()
    func prepare() throws {
      let editor = RecordEditorModel(
        properties: properties, original: nil, table: "notes", store: store
      ) {
        _, _ in
        Issue.record("Preparing a capture must not write a row")
        return [:]
      }
      try editor.installCaptureDraft(id: id, text: "Initial", column: "title")
      editor.setValue("Edited after capture", for: "title")
    }
    try prepare()
    let before = try #require(try store.all().first)
    let reopened = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Resuming a capture must not write a row")
      return [:]
    }
    try reopened.installCaptureDraft(id: id, text: "Initial", column: "title")
    #expect(reopened.recovery == nil && reopened.draft.values["title"] == "Edited after capture")
    let after = try store.all()
    #expect(after.count == 1 && after.first?.id == before.id)
  }

  @Test func redeliveryCannotForkADraftThatIsStillOpenInAnotherEditor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let id = UUID()
    let first = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Preparing must not write")
      return [:]
    }
    try first.installCaptureDraft(id: id, text: "Original", column: "title")
    first.setValue("Live edit", for: "title")
    let second = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Retry must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try second.installCaptureDraft(id: id, text: "Original", column: "title")
    }
    #expect(try store.all().count == 1 && first.draft.values["title"] == "Live edit")
  }

  @Test func captureRequiresARecoverableStore() throws {
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: nil
    ) {
      _, _ in
      Issue.record("An unrecoverable capture must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try editor.installCaptureDraft(id: UUID(), text: "Incoming", column: "title")
    }
    #expect(!editor.dirty)
  }

  @Test func anotherCaptureCannotReplaceAnExistingDirtyEditor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("Preparing a capture must not write a row")
      return [:]
    }
    editor.setValue("Keep this draft", for: "title")
    #expect(throws: WorkspaceError.self) {
      try editor.installCaptureDraft(id: UUID(), text: "Incoming", column: "title")
    }
    #expect(editor.draft.patch == ["title": .string("Keep this draft")])
  }

  @Test(arguments: ["id", "retired", "qty", "missing"])
  func captureRefusesNonTextOrUnavailableColumns(_ column: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("An invalid capture must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try editor.installCaptureDraft(id: UUID(), text: "Incoming", column: column)
    }
    #expect(!editor.dirty)
  }

  @Test func emptyQuickAddPersistsButOversizedInputDoesNotReplaceIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root, workspace: root.appendingPathComponent("sample.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "notes", store: store
    ) {
      _, _ in
      Issue.record("An empty quick add must not write")
      return [:]
    }
    #expect(throws: WorkspaceError.self) {
      try editor.installCaptureDraft(
        id: UUID(), text: String(repeating: "é", count: 32_769), column: "title")
    }
    #expect(try store.all().isEmpty)
    try editor.installCaptureDraft(id: UUID(), text: nil, column: nil)
    try await editor.flushAutosave()
    #expect(try store.all().count == 1)
    #expect(try store.all().count == 1 && !editor.dirty)
  }
}
