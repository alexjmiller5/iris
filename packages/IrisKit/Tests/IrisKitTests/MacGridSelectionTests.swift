#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @MainActor struct MacGridSelectionTests {
    @Test func checkboxIsNotACatalogColumnAndPreservesActionAndHeaderTargets() {
      var selection = Set<Data>()
      var edited: [String] = []
      let title = CatalogField(property: ["col": .string("title")])
      let status = CatalogField(property: ["col": .string("status")])
      var grid = MacRecordTable(
        rows: [WorkspaceRow(record: ["id": .string("row")], label: "Row")],
        columns: [NativeGridColumn(field: status, width: 180)], titleField: title,
        editingRow: nil, editingColumn: nil, editorID: nil, actionsEnabled: true,
        onOpen: { _ in Issue.record("Selecting must not open a row") },
        onEdit: { _, column in edited.append(column) }, onSort: { _, _ in }, onFilter: { _ in },
        actions: [
          CoreRowAction(id: "review", label: "Review", values: ["status": .string("Ready")])
        ],
        layout: [
          CoreViewLayoutItem(kind: "column", id: "status"),
          CoreViewLayoutItem(kind: "action", id: "review"),
          CoreViewLayoutItem(kind: "column", id: "title"),
        ], canRunAction: true, editor: { EmptyView() })
      grid.selection = Binding(get: { selection }, set: { selection = $0 })
      let coordinator = grid.makeCoordinator()
      coordinator.edit(row: 0, column: 0)
      #expect(edited.isEmpty)
      #expect(coordinator.columnMenu(0) == nil)
      coordinator.edit(row: 0, column: 1)
      coordinator.edit(row: 0, column: 2)
      coordinator.edit(row: 0, column: 3)
      #expect(edited == ["status", "title"])
      #expect(coordinator.columnMenu(1)?.items.first?.representedObject as? String == "status")
      #expect(coordinator.columnMenu(2) == nil)
      #expect(coordinator.columnMenu(3)?.items.first?.representedObject as? String == "title")
    }

    @Test func selectionUsesExactLoadedIDsWithoutAWindow() {
      let rows = [
        WorkspaceRow(record: ["id": .string("café")], label: "First"),
        WorkspaceRow(record: ["id": .string("cafe\u{301}")], label: "Second"),
      ]
      var selection = Set<Data>()
      var grid = MacRecordTable(
        rows: rows, columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in },
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      grid.selection = Binding(get: { selection }, set: { selection = $0 })
      let coordinator = grid.makeCoordinator()
      let table = NSTableView()
      table.allowsMultipleSelection = true
      table.addTableColumn(NSTableColumn(identifier: .init("selection")))
      table.addTableColumn(NSTableColumn(identifier: .init("record")))
      table.dataSource = coordinator
      coordinator.table = table
      table.reloadData()
      table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
      let delegate: NSTableViewDelegate = coordinator
      delegate.tableViewSelectionDidChange?(
        Notification(name: NSTableView.selectionDidChangeNotification, object: table))
      #expect(selection == Set(rows.map(\.byteExactID)))
      #expect(selection.count == 2)
      #expect(table.window == nil)
    }
    @Test func checkboxTogglesExactIdentityAndRestoresAfterReordering() throws {
      let rows = [
        WorkspaceRow(record: ["id": .string("café")], label: "First"),
        WorkspaceRow(record: ["id": .string("cafe\u{301}")], label: "Second"),
      ]
      var selection = Set<Data>()
      var grid = MacRecordTable(
        rows: rows, columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: true,
        onOpen: { _ in Issue.record("Selection opened a record") },
        onEdit: { _, _ in Issue.record("Selection edited a record") },
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      grid.selection = Binding(get: { selection }, set: { selection = $0 })
      let coordinator = grid.makeCoordinator()
      let table = NSTableView()
      table.allowsMultipleSelection = true
      let checkbox = NSTableColumn(identifier: .init("selection"))
      table.addTableColumn(checkbox)
      table.addTableColumn(NSTableColumn(identifier: .init("record")))
      table.dataSource = coordinator
      coordinator.table = table
      table.reloadData()
      let button = try #require(
        coordinator.tableView(table, viewFor: checkbox, row: 0) as? NSButton)
      #expect(button.cell?.representedObject as? Data == rows[0].byteExactID)
      coordinator.toggleSelectedRow(button)
      #expect(selection == [rows[0].byteExactID])
      #expect(table.selectedRowIndexes == IndexSet(integer: 0))
      let reversed = MacRecordTable(
        rows: Array(rows.reversed()), columns: [], titleField: nil, editingRow: nil,
        editingColumn: nil,
        editorID: nil, actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in },
        selection: grid.selection, onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      coordinator.parent = reversed
      table.reloadData()
      coordinator.restoreSelection()
      #expect(table.selectedRowIndexes == IndexSet(integer: 1))
      // A retained checkbox must continue targeting its identity after the row moves.
      coordinator.toggleSelectedRow(button)
      #expect(selection.isEmpty)
      #expect(!coordinator.tableView(table, shouldReorderColumn: 0, toColumn: 1))
      #expect(!coordinator.tableView(table, shouldReorderColumn: 1, toColumn: 0))
      #expect(coordinator.tableView(table, shouldReorderColumn: 1, toColumn: 2))
      #expect(table.window == nil)
    }
    @Test func contextClickKeepsSelectedRowsAndMovesOnlyForAnUnselectedRow() throws {
      let rows = (0..<3).map { WorkspaceRow(record: ["id": .string("row-\($0)")], label: "Row") }
      let grid = MacRecordTable(
        rows: rows, columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in },
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      let coordinator = grid.makeCoordinator()
      let table = RecordTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
      table.allowsMultipleSelection = true
      table.addTableColumn(NSTableColumn(identifier: .init("record")))
      table.dataSource = coordinator
      table.delegate = coordinator
      table.reloadData()
      table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
      func click(_ row: Int) throws {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(
          NSEvent.mouseEvent(
            with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1))
        _ = table.menu(for: event)
      }
      try click(1)
      #expect(table.selectedRowIndexes == IndexSet([0, 1]))
      try click(2)
      #expect(table.selectedRowIndexes == IndexSet(integer: 2))
      #expect(table.window == nil)
    }
    @Test func restoringSelectionDoesNotPublishViewUpdateAndIgnoresForeignTables() {
      let row = WorkspaceRow(record: ["id": .string("row")], label: "Row")
      var ids: Set<Data> = [row.byteExactID]
      var writes = 0
      let grid = MacRecordTable(
        rows: [row], columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in },
        selection: Binding(
          get: { ids },
          set: {
            ids = $0
            writes += 1
          }),
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      let coordinator = grid.makeCoordinator()
      let table = NSTableView()
      table.addTableColumn(NSTableColumn(identifier: .init("selection")))
      table.dataSource = coordinator
      table.delegate = coordinator
      coordinator.table = table
      coordinator.applyingColumns = true
      table.reloadData()
      coordinator.restoreSelection()
      #expect(coordinator.applyingColumns)
      coordinator.applyingColumns = false
      #expect(table.selectedRowIndexes == IndexSet(integer: 0))
      #expect(writes == 0)
      coordinator.tableViewSelectionDidChange(
        Notification(name: NSTableView.selectionDidChangeNotification, object: NSTableView()))
      #expect(ids == [row.byteExactID] && writes == 0)
      table.deselectAll(nil)
      #expect(ids.isEmpty && writes == 1)
      #expect(table.window == nil)
    }
  }
#endif
