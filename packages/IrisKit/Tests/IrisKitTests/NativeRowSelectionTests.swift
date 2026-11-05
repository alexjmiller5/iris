import Foundation
import Testing

@testable import IrisKit

struct NativeRowSelectionTests {
  @Test func exactIDsSurviveSortingButFilteredRowsDoNotReturn() {
    let owner = NSObject()
    let scope = NativeRowSelection.Scope(
      workspace: ObjectIdentifier(owner), generation: 1, table: Data("rows".utf8))
    let rows = [
      WorkspaceRow(record: ["id": .string("café")], label: "First"),
      WorkspaceRow(record: ["id": .string("cafe\u{301}")], label: "Second"),
    ]
    var selection = NativeRowSelection()
    selection.set(Set(rows.map(\.byteExactID)), in: scope, rows: rows)
    #expect(selection.selected(in: scope, rows: Array(rows.reversed())).count == 2)
    selection.retain(in: scope, rows: [rows[1]])
    #expect(selection.selected(in: scope, rows: rows) == [rows[1].byteExactID])
    selection.set([rows[0].byteExactID, Data("unloaded".utf8)], in: scope, rows: rows)
    #expect(selection.selected(in: scope, rows: rows) == [rows[0].byteExactID])
  }
  @Test func workspaceGenerationAndExactTableScopeCannotLeakSelection() {
    let owner = NSObject()
    let other = NSObject()
    let scopes = [
      NativeRowSelection.Scope(
        workspace: ObjectIdentifier(owner), generation: 1, table: Data("café".utf8)),
      NativeRowSelection.Scope(
        workspace: ObjectIdentifier(owner), generation: 1, table: Data("cafe\u{301}".utf8)),
      NativeRowSelection.Scope(
        workspace: ObjectIdentifier(owner), generation: 2, table: Data("café".utf8)),
      NativeRowSelection.Scope(
        workspace: ObjectIdentifier(other), generation: 1, table: Data("café".utf8)),
    ]
    let rows = [WorkspaceRow(record: ["id": .string("row")], label: "Row")]
    var selection = NativeRowSelection()
    selection.set([rows[0].byteExactID], in: scopes[0], rows: rows)
    #expect(selection.selected(in: scopes[0], rows: rows).count == 1)
    for scope in scopes.dropFirst() { #expect(selection.selected(in: scope, rows: rows).isEmpty) }
    selection.retain(in: scopes[1], rows: rows)
    #expect(selection.selected(in: scopes[0], rows: rows).isEmpty)
    selection.set([rows[0].byteExactID], in: nil, rows: rows)
    #expect(selection.selected(in: nil, rows: rows).isEmpty)
  }
}
