import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct OpaqueIdentityBehaviorTests {
  private let first = "\u{00e9}"
  private let second = "e\u{0301}"
  private let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("topic"), "type": .string("ref")],
    ["col": .string("related"), "type": .string("multi_ref")],
  ]
  private func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
  private func row(_ id: String, title: String = "Fixture") -> WorkspaceRow {
    WorkspaceRow(
      record: ["id": .string(id), "title": .string(title), "updated_at": .string("v1")],
      label: title)
  }
  private func editor(_ id: String, store: EditorDraftStore? = nil) -> RecordEditorModel {
    RecordEditorModel(
      properties: properties, original: row(id).record, table: "notes", store: store
    ) { _, _ in
      throw WorkspaceError(message: "Unexpected write", violations: [])
    }
  }

  @Test func recoveryAndRealSaveNeverCrossSQLiteRecordIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"), workspace: root.appendingPathComponent("db"))
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    runtime.context.evaluateScript(
      #"""
      IrisSql.run("INSERT INTO notes (id,title) VALUES (?,?),(?,?)",
        ['\u00e9','First stored','e\u0301','Second stored']);
      """#)
    try #require(runtime.context.exception == nil)
    let rows = try await client.rows(table: "notes")
    let a = try #require(rows.first { bytes($0.id) == bytes(first) })
    let b = try #require(rows.first { bytes($0.id) == bytes(second) })
    var initial: RecordEditorModel? = RecordEditorModel(
      properties: properties, original: a.record, table: "notes", store: store
    ) { _, _ in throw WorkspaceError(message: "First draft must stay unsaved", violations: []) }
    initial?.setValue("First retained draft", for: "title")
    initial = nil
    #expect(try store.load(table: "notes", recordID: second) == nil)
    let editing = RecordEditorModel(
      properties: properties, original: b.record, table: "notes", store: store
    ) { patch, baseline in
      try await client.write(
        table: "notes", patch: patch, expectedUpdatedAt: baseline?["updated_at"]?.text)
    }
    #expect(editing.recoveryChoices.isEmpty)
    editing.resumeDraft()  // Must be harmless when only another record has a journal.
    #expect(bytes(editing.draft.original?["id"]?.text) == bytes(second))
    editing.setValue("Second saved", for: "title")
    try await editing.saveAll()
    let savedRows = try await client.rows(table: "notes")
    #expect(
      savedRows.first { bytes($0.id) == bytes(first) }?.record["title"] == .string("First stored"))
    #expect(
      savedRows.first { bytes($0.id) == bytes(second) }?.record["title"] == .string("Second saved"))
    let retained = try #require(try store.load(table: "notes", recordID: first))
    #expect(retained.draft.values["title"] == "First retained draft")
    let reopened = editor(first, store: store)
    reopened.resumeDraft()
    #expect(bytes(reopened.draft.original?["id"]?.text) == bytes(first))
    #expect(reopened.draft.values["title"] == "First retained draft")
    try await client.close()
  }

  @Test func journalsWithBothIDsLoadIndependently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"), workspace: root.appendingPathComponent("db"))
    let a = editor(first, store: store)
    a.setValue("First draft", for: "title")
    let b = editor(second, store: store)
    b.setValue("Second draft", for: "title")
    #expect(try store.all().count == 2)
    #expect(try store.load(table: "notes", recordID: first)?.draft.values["title"] == "First draft")
    #expect(
      try store.load(table: "notes", recordID: second)?.draft.values["title"] == "Second draft")
    try b.discardDraft()
    #expect(try store.load(table: "notes", recordID: first) != nil)
  }

  @Test func undoOtherByteDistinctRecordDoesNotReplaceEditorBaseline() async throws {
    let source = editor(second)
    source.setValue("Second retained", for: "title")
    let action = CoreUndoAction(receiptId: "fixture", table: "notes", rowId: first, kind: .edit)
    try await source.performUndo(action) { row(first, title: "First undone").record }
    #expect(bytes(source.draft.original?["id"]?.text) == bytes(second))
    #expect(source.draft.values["title"] == "Second retained")
    #expect(bytes(source.draft.patch["id"]?.text) == bytes(second))
  }

  @Test func referenceSelectionChangesAndRemovalUseExactIDs() throws {
    var scalar = try ReferenceSelection(value: first, multiple: false)
    scalar.choose(second)
    #expect(bytes(scalar.value) == bytes(second))
    var multi = try ReferenceSelection(value: "[]", multiple: true)
    multi.choose(first)
    multi.choose(second)
    #expect(multi.ids.map { Data($0.utf8) } == [Data(first.utf8), Data(second.utf8)])
    multi.remove(first)
    #expect(multi.ids.map { Data($0.utf8) } == [Data(second.utf8)])
    let decoded = try JSONDecoder().decode([String].self, from: Data(multi.value.utf8))
    #expect(decoded.map { Data($0.utf8) } == [Data(second.utf8)])
  }

  @Test(arguments: ["topic", "related"])
  func referenceDraftPreservesChangedIDsAndLaterTyping(column: String) {
    let a = column == "topic" ? first : "[\"\(first)\"]"
    let b = column == "topic" ? second : "[\"\(second)\"]"
    var original = row("source").record
    original[column] = .string(a)
    let source = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: nil
    ) { _, _ in [:] }
    source.setValue(b, for: column)
    #expect(source.dirty)
    #expect(bytes(source.draft.patch[column]?.text) == bytes(b))
    var draft = RecordDraft(properties: properties, original: original)
    draft.values[column] = b
    var receipt = original
    receipt[column] = .string("other-target")
    draft.acknowledge(receipt, sent: [column: .string(a)])
    #expect(
      bytes(draft.values[column]) == bytes(b), "A late receipt must preserve a newer selection")
    var undoDraft = RecordDraft(properties: properties, original: original)
    undoDraft.values[column] = b
    undoDraft.reconcileUndo(receipt)
    #expect(bytes(undoDraft.values[column]) == bytes(b))
  }

  @Test func referenceLabelsAndFreshReadsDoNotAlias() async throws {
    let rows = [row(first, title: "First label"), row(second, title: "Second label")]
    let picker = try ReferencePickerModel(
      table: "notes", value: "[]", multiple: true, load: { _ in rows })
    await picker.reload()
    picker.choose(rows[0])
    picker.choose(rows[1])
    #expect(picker.label(for: first) == "First label")
    #expect(picker.label(for: second) == "Second label")
    #expect(picker.selection.ids.count == 2)
    // A mismatched reply cannot supply a label for another exact ID.
    let unavailable = try ReferencePickerModel(
      table: "notes", value: second, multiple: false, load: { _ in [rows[0]] })
    await unavailable.resolveSelected()
    #expect(unavailable.label(for: second) == "Unavailable")
    let selected = String(decoding: try JSONEncoder().encode([first, second]), as: UTF8.self)
    let guarded = try ReferencePickerModel(
      table: "notes", value: selected, multiple: true,
      load: { view in
        // One any-of lookup for both exact IDs; a row for one never labels the other.
        let requested = (view.groups?.first?.filters ?? []).compactMap { filter -> String? in
          if case .string(let value) = filter.value { return value }
          return nil
        }
        #expect(requested.map(bytes) == [bytes(first), bytes(second)])
        return [row(first, title: "First label")]
      })
    await guarded.resolveSelected()
    #expect(guarded.label(for: first) == "First label")
    #expect(guarded.label(for: second) == "Unavailable")
  }

  @Test func quickFindKeepsBothIDsAcrossPagesAndRejectsWrongFreshRow() async throws {
    func hit(_ id: String) -> CoreSearchHit {
      CoreSearchHit(table: "notes", id: id, label: "Fixture", excerpt: "")
    }
    var wrong = false
    var offsets: [Int?] = []
    let find = QuickFindModel(
      search: { args in
        offsets.append(args.offset)
        return args.offset == 0
          ? [hit(first)] + (0..<49).map { hit("filler-\($0)") } : [hit(first), hit(second)]
      }, read: { _ in [row(wrong ? first : second)] })
    find.query = "fixture"
    await find.reload()
    await find.reload(more: true)
    #expect(offsets == [0, 50])
    #expect(find.results.count == 51)
    #expect(await find.open(hit(second)) != nil)
    wrong = true
    #expect(await find.open(hit(second)) == nil)
  }

  @Test func onlinePagesAndPendingExactLookupKeepByteIdentity() async throws {
    func remote(_ id: String, label: String) -> CoreRemoteRecord {
      CoreRemoteRecord(record: ["id": .string(id)], label: label, deleted: false)
    }
    var held: CheckedContinuation<CoreRemoteRowResult, any Error>?
    let online = OnlineBrowseModel(
      table: "notes",
      load: { cursor in
        CoreRemoteRowsPage(
          rows: cursor == nil
            ? [remote(first, label: "First")]
            : [remote(first, label: "Updated first"), remote(second, label: "Second")],
          nextCursor: cursor == nil ? "next" : nil)
      }, read: { _ in try await withCheckedThrowingContinuation { held = $0 } })
    await online.reload()
    await online.reload(more: true)
    #expect(online.rows.count == 2)
    #expect(online.rows.map(\.label) == ["Updated first", "Second"])
    online.recordID = first
    let pending = Task { await online.open(id: first) }
    while held == nil { await Task.yield() }
    online.recordID = second
    held?.resume(returning: CoreRemoteRowResult(row: remote(first, label: "Late first")))
    await pending.value
    #expect(online.selected == nil)
    #expect(online.opening == nil)
  }

  @Test func relatedNavigationRejectsWrongIDAndChangedReferenceDraftDuringDiscard() async throws {
    #expect(
      RecordReference(table: "notes", id: first) != RecordReference(table: "notes", id: second))
    let source = editor("source")
    let wrong = ReferenceNavigationModel(editor: source, read: { _ in [row(first)] })
    #expect(await wrong.open(table: "notes", id: second) == nil)
    source.setValue(first, for: "topic")
    var held: CheckedContinuation<[WorkspaceRow], any Error>?
    var calls = 0
    var opened = false
    let navigation = ReferenceNavigationModel(
      editor: source,
      read: { _ in
        calls += 1
        if calls == 2 { return try await withCheckedThrowingContinuation { held = $0 } }
        return [row("destination")]
      }, onOpen: { _ in opened = true })
    #expect(await navigation.open(table: "notes", id: "destination") == nil)
    let pending = Task { await navigation.discardAndOpen() }
    while held == nil { await Task.yield() }
    source.setValue(second, for: "topic")
    held?.resume(returning: [row("destination")])
    #expect(await pending.value == nil)
    #expect(!opened && navigation.error != nil)
    #expect(bytes(source.draft.values["topic"]) == bytes(second))
  }
}
