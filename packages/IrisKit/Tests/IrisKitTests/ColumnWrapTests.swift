import Foundation
import Testing

@testable import IrisKit

@MainActor
struct ColumnWrapTests {
  @Test func wrappedColumnsSaveWithTheViewAndUndoRevertsThem() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let opened = try #require(model.appliedView)
    #expect(model.wrapColumns.isEmpty)
    #expect(try model.currentViewDefinition().wrap == nil)
    model.setWrap(column: "title", true)
    model.setWrap(column: "status", true)
    model.setWrap(column: "status", true)
    #expect(model.wraps("title") && model.wraps("status") && !model.wraps("body"))
    let definition = try model.currentViewDefinition()
    #expect(definition.wrap == ["title", "status"])
    #expect(definition.version == 2)
    #expect(model.viewModified)
    model.scheduleViewSave(after: .zero)
    await model.flushViewSave()
    let saved = try #require(model.appliedView)
    #expect(saved.byteExactID == opened.byteExactID)
    #expect(saved.definition?.wrap == ["title", "status"])
    let stored = try await context.workspace.listViews(table: "notes").views.first {
      $0.byteExactID == opened.byteExactID
    }
    #expect(stored?.definition?.wrap == ["title", "status"])
    model.setWrap(column: "title", false)
    #expect(try model.currentViewDefinition().wrap == ["status"])
    model.setWrap(column: "status", false)
    #expect(try model.currentViewDefinition().wrap == nil, "No wrapped column saves no wrap")
    model.setWrap(column: "title", true)
    model.scheduleViewSave(after: .zero)
    try await model.undoLatest(context: context)
    #expect(model.wrapColumns == ["title", "status"], "Undo reverts the latest wrap change")
    await model.close()
  }

  @Test func wrapAllCoversEveryShownColumnAndClearsThemTogether() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    model.setWrapAll(true, columns: ["title", "status"])
    #expect(model.wrapColumns == ["title", "status"])
    #expect(model.wrapsAll(["title", "status"]))
    #expect(!model.wrapsAll(["title", "status", "body"]))
    model.setWrapAll(false, columns: ["title", "status"])
    #expect(model.wrapColumns.isEmpty)
    await model.close()
  }
}

#if os(macOS)
  import AppKit
  import SwiftUI

  @MainActor
  struct MacColumnWrapTests {
    @Test func headerMenuTogglesWrapTextAndWrappedRowsGrow() async throws {
      let title = CatalogField(property: ["col": .string("title")])
      let note = CatalogField(property: ["col": .string("note"), "type": .string("text")])
      let row = WorkspaceRow(record: ["id": .string("row"), "note": .string("Long")], label: "Row")
      var toggled: [(String, Bool)] = []
      let grid = MacRecordTable(
        rows: [row], columns: [NativeGridColumn(field: note, width: 180)],
        titleField: title, editingRow: nil, editingColumn: nil, editorID: nil,
        actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in }, onSort: { _, _ in },
        onFilter: { _ in }, wrapped: ["note"], onWrap: { toggled.append(($0, $1)) }
      ) { EmptyView() }
      let coordinator = grid.makeCoordinator()
      let wrap = try #require(coordinator.columnMenu(1)?.items.first { $0.title == "Wrap text" })
      #expect(wrap.state == .on)
      #expect(coordinator.columnMenu(0)?.items.first { $0.title == "Wrap text" }?.state == .off)
      coordinator.columnAction(wrap)
      #expect(toggled.map(\.0) == ["note"] && toggled.map(\.1) == [false])
      let table = NSTableView()
      #expect(coordinator.tableView(table, heightOfRow: 0) == 28)
      coordinator.resizeWrapped(64, row: row.byteExactID, column: "note")
      coordinator.resizeWrapped(90, row: row.byteExactID, column: "title")
      for _ in 0..<20 { await Task.yield() }
      #expect(coordinator.tableView(table, heightOfRow: 0) == 76, "Only wrapped columns size rows")
    }
  }
#endif
