import Foundation
import Testing

@testable import IrisKit

/// Record editors save themselves: choices on change, typed fields after an idle
/// pause or on blur, Markdown on its own pause. Each write is one receipt.
@MainActor
struct RecordAutosaveTests {
  let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text"), "required": .bool(true)],
    ["col": .string("status"), "type": .string("select")],
    ["col": .string("size"), "type": .string("number")],
    ["col": .string("body"), "type": .string("markdown")],
  ]
  let original: WorkspaceRecord = [
    "id": .string("fixture"), "title": .string("Original"), "status": .string("Open"),
    "size": .string("1"), "body": .string("Old"), "updated_at": .string("revision-1"),
  ]

  /// A writer that stamps a new revision and records every patch.
  final class Writer {
    var patches: [WorkspaceRecord] = []
    var revisions: [String?] = []
    var stored: WorkspaceRecord
    var refuse: ((WorkspaceRecord) -> WorkspaceError?)?
    init(_ stored: WorkspaceRecord) { self.stored = stored }
    @MainActor func write(_ patch: WorkspaceRecord, _ baseline: WorkspaceRecord?) throws
      -> WorkspaceRecord
    {
      patches.append(patch)
      revisions.append(baseline?["updated_at"]?.text)
      if let error = refuse?(patch) { throw error }
      var next = stored
      for (key, value) in patch { next[key] = value }
      next["updated_at"] = .string("revision-\(patches.count + 1)")
      stored = next
      return next
    }
  }

  func editor(
    _ writer: Writer, original: WorkspaceRecord? = nil, typing: Duration = .milliseconds(40),
    markdown: Duration = .milliseconds(60)
  ) -> RecordEditorModel {
    RecordEditorModel(
      properties: properties, original: original ?? self.original, table: "items", store: nil,
      debounce: markdown, typingDelay: typing
    ) { patch, baseline in try writer.write(patch, baseline) }
  }

  func settle(_ editor: RecordEditorModel, _ duration: Duration = .milliseconds(150)) async throws {
    try await Task.sleep(for: duration)
    try await editor.flushAutosave()
  }

  @Test func typedFieldsWaitForAPauseAndWriteOnlyTheChangedField() async throws {
    let writer = Writer(original)
    let editor = editor(writer)
    editor.setValue("O", for: "title")
    editor.setValue("Ok", for: "title")
    try await Task.sleep(for: .milliseconds(10))
    #expect(writer.patches.isEmpty)
    try await Task.sleep(for: .milliseconds(120))
    #expect(writer.patches == [["id": .string("fixture"), "title": .string("Ok")]])
    #expect(writer.revisions == ["revision-1"])
    #expect(editor.saved)
  }

  @Test func choicesCommitOnChangeWithoutAPause() async throws {
    let writer = Writer(original)
    let editor = editor(writer, typing: .seconds(60), markdown: .seconds(60))
    editor.setValue("Done", for: "status")
    for _ in 0..<50 where writer.patches.isEmpty { await Task.yield() }
    #expect(writer.patches == [["id": .string("fixture"), "status": .string("Done")]])
  }

  @Test func leavingAFieldCommitsItAtOnce() async throws {
    let writer = Writer(original)
    let editor = editor(writer, typing: .seconds(60))
    editor.setValue("Blurred", for: "title")
    editor.commitPending()
    for _ in 0..<50 where writer.patches.isEmpty { await Task.yield() }
    #expect(writer.patches == [["id": .string("fixture"), "title": .string("Blurred")]])
  }

  @Test func eachPauseIsItsOwnWriteWithTheLatestRevision() async throws {
    let writer = Writer(original)
    let editor = editor(writer)
    editor.setValue("Done", for: "status")
    try await settle(editor)
    editor.setValue("Second", for: "title")
    try await settle(editor)
    #expect(writer.patches.count == 2)
    #expect(writer.revisions == ["revision-1", "revision-2"])
    #expect(editor.draft.original?["updated_at"] == .string("revision-3"))
  }

  @Test func aRefusedValueStaysEditableWhileTheRestSaves() async throws {
    let writer = Writer(original)
    writer.refuse = { patch in
      patch["size"] == .string("abc")
        ? WorkspaceError(
          message: "items[fixture].size: Must be a number.",
          violations: [Violation(col: "size", rule: "type", message: "Must be a number.")])
        : nil
    }
    let editor = editor(writer, typing: .seconds(60))
    editor.setValue("abc", for: "size")
    editor.setValue("Done", for: "status")
    try await settle(editor, .milliseconds(20))
    #expect(writer.stored["status"] == .string("Done"))
    #expect(writer.stored["size"] == .string("1"))
    #expect(editor.draft.values["size"] == "abc")
    #expect(editor.fieldViolations.map(\.col) == ["size"])
    #expect(editor.failure == nil)
    // The refused value is not retried until it changes.
    let attempts = writer.patches.count
    try await editor.flushAutosave()
    #expect(writer.patches.count == attempts)
    editor.setValue("12", for: "size")
    try await editor.flushAutosave()
    #expect(writer.stored["size"] == .string("12"))
    #expect(editor.fieldViolations.isEmpty)
  }

  @Test func aConflictMergesTheStoredRowAndRetriesOnlyLocalEdits() async throws {
    let writer = Writer(original)
    var first = true
    writer.refuse = { _ in
      defer { first = false }
      return first
        ? WorkspaceError(
          message: "Row changed since it was selected.",
          violations: [Violation(col: "updated_at", rule: "conflict", message: "Row changed.")])
        : nil
    }
    let editor = editor(writer, typing: .seconds(60))
    // Another writer changed status meanwhile.
    writer.stored["status"] = .string("Remote")
    writer.stored["updated_at"] = .string("revision-remote")
    editor.latest = { writer.stored }
    editor.setValue("Mine", for: "title")
    try await editor.flushAutosave()
    #expect(writer.patches.last == ["id": .string("fixture"), "title": .string("Mine")])
    #expect(writer.revisions.last == "revision-remote")
    #expect(editor.draft.values["status"] == "Remote")
    #expect(editor.draft.values["title"] == "Mine")
    #expect(editor.failure == nil)
  }

  @Test func aRemoteEditNeverClobbersTheFieldBeingTypedIn() async throws {
    let writer = Writer(original)
    let editor = editor(writer, typing: .seconds(60))
    editor.setValue("Typing", for: "title")
    var remote = original
    remote["title"] = .string("Remote title")
    remote["status"] = .string("Remote status")
    remote["updated_at"] = .string("revision-remote")
    editor.adoptStored(remote, focused: "title")
    #expect(editor.draft.values["title"] == "Typing")
    #expect(editor.draft.values["status"] == "Remote status")
    #expect(editor.draft.original?["updated_at"] == .string("revision-remote"))
    try await editor.flushAutosave()
    #expect(writer.patches == [["id": .string("fixture"), "title": .string("Typing")]])
    #expect(writer.revisions == ["revision-remote"])
    // Already saved but still being typed in: a newer remote value does not replace it.
    var later = writer.stored
    later["title"] = .string("Remote again")
    later["updated_at"] = .string("revision-later")
    editor.adoptStored(later, focused: "title")
    #expect(editor.draft.values["title"] == "Typing")
    editor.adoptStored(later)
    #expect(editor.draft.values["title"] == "Typing", "kept as the newer local edit")
  }

  @Test func aNewRecordIsCreatedByItsFirstValidEdit() async throws {
    let writer = Writer([:])
    writer.refuse = { patch in
      patch["title"] == nil
        ? WorkspaceError(
          message: "title required",
          violations: [Violation(col: "title", rule: "required", message: "Title is required.")])
        : nil
    }
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "items", store: nil,
      debounce: .milliseconds(60), typingDelay: .milliseconds(20)
    ) { patch, baseline in
      var created = try writer.write(patch, baseline)
      if created["id"] == nil { created["id"] = .string("created") }
      writer.stored = created
      return created
    }
    editor.setValue("Done", for: "status")
    // A missing required field refuses the creation; it shows at that field.
    await #expect(throws: WorkspaceError.self) { try await settle(editor, .milliseconds(30)) }
    #expect(editor.isNew)
    #expect(editor.fieldViolations.map(\.col) == ["title"])
    editor.setValue("Named", for: "title")
    try await settle(editor)
    #expect(!editor.isNew)
    #expect(editor.draft.original?["id"] == .string("created"))
    editor.setValue("Renamed", for: "title")
    try await settle(editor)
    #expect(writer.patches.last == ["id": .string("created"), "title": .string("Renamed")])
  }

  @Test func aListedRowPaintsFirstAndEditsWaitForTheFreshRow() async throws {
    let writer = Writer(original)
    var listed = original
    listed["body"] = .string("Ol")  // a list row can be truncated
    let editor = RecordEditorModel(
      properties: properties, original: listed, table: "items", store: nil,
      debounce: .milliseconds(20), typingDelay: .milliseconds(20), loaded: false
    ) { patch, baseline in try writer.write(patch, baseline) }
    #expect(editor.draft.values["title"] == "Original")
    #expect(!editor.loaded)
    editor.setValue("Early", for: "title")
    try await Task.sleep(for: .milliseconds(60))
    // Done before the fresh row arrives writes nothing against the listed revision.
    try await editor.flushAutosave()
    #expect(writer.patches.isEmpty)
    editor.adoptStored(original)
    #expect(editor.loaded)
    #expect(editor.draft.values["body"] == "Old")
    try await settle(editor)
    #expect(writer.patches == [["id": .string("fixture"), "title": .string("Early")]])
  }

  @Test func realCoreEachAutosaveIsOneUndoStep() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let row = try #require(model.rows.first?.record)
    let editor = RecordEditorModel(
      properties: model.properties, original: row, table: context.table, store: nil,
      debounce: .seconds(60), typingDelay: .seconds(60)
    ) { patch, baseline in
      try await model.save(patch, original: baseline, context: context)
    }
    editor.latest = {
      try await context.workspace.rows(
        view: CoreView(
          table: context.table,
          filters: [
            CoreFilter(
              column: "id", op: .eq,
              value: row["id"].map { CoreFilterValue.string($0.text) } ?? .null)
          ],
          limit: 1)
      ).first?.record
    }
    editor.setValue("Autosaved title", for: "title")
    try await editor.flushAutosave()
    editor.setValue("# Autosaved body", for: "body")
    try await editor.flushAutosave()
    // Another client edits; the next autosave merges instead of failing.
    let stored = try #require(try await context.workspace.rows(table: "notes").first?.record)
    _ = try await context.workspace.write(
      table: "notes", patch: ["id": row["id"]!, "status": .string("Ready")],
      expectedUpdatedAt: stored["updated_at"]?.text)
    editor.setValue("After remote", for: "title")
    try await editor.flushAutosave()
    var latest = try #require(try await context.workspace.rows(table: "notes").first?.record)
    #expect(latest["title"] == .string("After remote"))
    #expect(latest["status"] == .string("Ready"))
    #expect(latest["body"] == .string("# Autosaved body"))
    // Undo reverts exactly the latest autosave.
    let action = try #require(try await context.workspace.undoStatus().action)
    _ = try await model.undo(action, context: context)
    latest = try #require(try await context.workspace.rows(table: "notes").first?.record)
    #expect(latest["title"] == .string("Autosaved title"))
    #expect(latest["body"] == .string("# Autosaved body"))
    #expect(latest["status"] == .string("Ready"))
    await model.close()
  }
}
