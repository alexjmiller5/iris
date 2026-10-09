import Foundation
import Testing

@testable import IrisKit

@MainActor
struct LinkedFromTests {
  @Test func realCoreListsNotesWhoseMarkdownMentionsTheRecord() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    let note = try await workspace.write(
      table: "notes",
      patch: [
        "title": .string("Mentions a topic"),
        "body": .string("See [Topic](iris://table/topics/row/\(topic.id)) for context."),
      ])
    let model = LinkedFromModel(
      table: "topics", rowID: topic.id, readPage: { try await workspace.mentionedBy($0) })
    await model.load()
    #expect(model.rows.map(\.id) == [note["id"]?.text])
    #expect(model.rows.first?.label == "Mentions a topic")
    #expect(model.rows.first?.table == "notes")
    #expect(model.error == nil && model.loaded)
    try await workspace.close()
  }

  @Test func editorReadsAllowOnlyReadOnlyLinkOperations() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    let labels = try await workspace.editorRead(
      "mentionLabels", arguments: #"{"targets":[{"table":"topics","id":"\#(topic.id)"}]}"#)
    guard case .array(let items) = labels, case .object(let first) = items.first else {
      Issue.record("Expected label array")
      return
    }
    #expect(first["label"] == .string(topic.label))
    await #expect(throws: WorkspaceError.self) {
      _ = try await workspace.editorRead(
        "write", arguments: #"{"table":"topics","patch":{"title":"Changed"}}"#)
    }
    #expect(try await workspace.rows(table: "topics").first?.label == topic.label)
    try await workspace.close()
  }

  @Test func pagesAppendDeduplicateAndRefreshFromTheFirstPage() async throws {
    var offsets: [Int] = []
    let model = LinkedFromModel(table: "topics", rowID: "t") { args in
      offsets.append(args.offset ?? 0)
      #expect(args.table == "topics" && args.rowId == "t" && args.limit == 20)
      return args.offset == 20
        ? CoreMentionedByPage(
          rows: [Self.row("b"), Self.row("c")], nextOffset: nil, incomplete: true)
        : CoreMentionedByPage(
          rows: [Self.row("a"), Self.row("b")], nextOffset: 20, incomplete: false)
    }
    await model.load()
    await model.load(more: true)
    #expect(model.rows.map(\.id) == ["a", "b", "c"])
    #expect(model.incomplete && model.nextOffset == nil)
    await model.load()
    #expect(model.rows.map(\.id) == ["a", "b"])
    #expect(offsets == [0, 20, 0])
  }

  @Test func staleOrDisposedReadsNeverReplaceRows() async throws {
    var current = true
    let model = LinkedFromModel(
      table: "topics", rowID: "t",
      readPage: { _ in
        current = false
        return CoreMentionedByPage(rows: [Self.row("late")], nextOffset: nil, incomplete: false)
      }, isCurrent: { current })
    await model.load()
    #expect(model.rows.isEmpty && !model.loaded)
    let failing = LinkedFromModel(table: "topics", rowID: "t") { _ in
      throw WorkspaceError(message: "Index unavailable", violations: [])
    }
    await failing.load()
    #expect(failing.error == "Index unavailable" && !failing.loading)
    failing.dispose()
    #expect(failing.isDisposed)
  }

  private static func row(_ id: String) -> CoreMentionedByRow {
    CoreMentionedByRow(table: "notes", id: id, label: "Note \(id)")
  }
}
