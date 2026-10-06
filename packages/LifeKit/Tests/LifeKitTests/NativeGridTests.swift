import Foundation
import Testing

@testable import LifeKit

struct NativeGridTests {
  private let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "label": .string("Title"), "type": .string("text")],
    ["col": .string("done"), "label": .string("Complete"), "type": .string("bool")],
    ["col": .string("body"), "label": .string("Content"), "type": .string("markdown")],
  ]

  @Test func savedColumnsKeepOrderAndHideUnselectedFields() {
    let columns = NativeGridColumn.columns(properties: properties, selected: ["done", "title"])
    #expect(columns.map(\.id) == ["done", "title"])
    #expect(columns.map(\.label) == ["Complete", "Title"])
  }

  @Test func absentLayoutUsesCatalogOrderButExplicitEmptyStaysEmpty() {
    #expect(
      NativeGridColumn.columns(properties: properties).map(\.id) == ["title", "done", "body"])
    #expect(NativeGridColumn.columns(properties: properties, selected: []).isEmpty)
  }

  @Test func staleOrRepeatedColumnsDoNotProduceDuplicateTableColumns() {
    let columns = NativeGridColumn.columns(
      properties: properties, selected: ["gone", "body", "body", "done"])
    #expect(columns.map(\.id) == ["body", "done"])
  }

  @Test func importedWidthsApplyToTheirColumnOnly() {
    let columns = NativeGridColumn.columns(properties: properties, widths: ["done": 300])
    #expect(columns.map(\.width) == [180, 300, 360])
  }

  @Test func booleanCellsDisplayStoredFalseAndUnknownAsDifferentValues() throws {
    let column = try #require(
      NativeGridColumn.columns(properties: properties).first { $0.id == "done" })
    #expect(column.text(in: ["done": .number(0)]) == "false")
    #expect(column.text(in: ["done": .number(1)]) == "true")
    #expect(column.text(in: ["done": .null]) == "")
  }

  @Test func tableIdentityKeepsDistinctOpaqueRecordsAndFullEditorPayload() {
    let first = NativeGridRow(
      row: WorkspaceRow(
        record: ["id": .string("\u{e9}"), "body": .string("hidden source")], label: "First"))
    let second = NativeGridRow(
      row: WorkspaceRow(record: ["id": .string("e\u{301}")], label: "Second"))
    #expect(Set([first.id, second.id]).count == 2)
    #expect(first.row.record["body"] == .string("hidden source"))
    #expect(second.row.label == "Second")
  }

  @Test func keyboardAndContextActionsResolveOnlyTheExactSingleSelection() {
    let first = WorkspaceRow(record: ["id": .string("\u{e9}")], label: "First")
    let second = WorkspaceRow(record: ["id": .string("e\u{301}")], label: "Second")
    let rows = [first, second]
    #expect(NativeGridRow.selected(in: rows, ids: [second.byteExactID])?.label == "Second")
    #expect(NativeGridRow.selected(in: rows, ids: []) == nil)
    #expect(NativeGridRow.selected(in: rows, ids: [Data("missing".utf8)]) == nil)
    #expect(NativeGridRow.selected(in: rows, ids: [first.byteExactID, second.byteExactID]) == nil)
  }
}
