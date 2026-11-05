#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @MainActor struct MacDuplicateShortcutTests {
    @Test func commandDDuplicatesOnlyOnceWithoutOpeningAWindow() throws {
      let table = RecordTableView()
      var calls = 0
      table.duplicateSelection = {
        calls += 1
        return true
      }
      let key = try event("d", flags: .command)
      #expect(table.handleDuplicateShortcut(key, responder: table))
      #expect(!table.handleDuplicateShortcut(key, responder: NSTextView()))
      #expect(!table.handleDuplicateShortcut(key, responder: RecordTableView()))
      #expect(calls == 1)
      #expect(!table.handleDuplicateShortcut(key, responder: nil))
      table.duplicateSelection = nil
      #expect(!table.handleDuplicateShortcut(key, responder: table))
      #expect(table.window == nil)
    }

    @Test func otherModifiersAndRepeatDoNotClaimTheShortcut() throws {
      for flags: NSEvent.ModifierFlags in [
        [], .shift, [.command, .shift],
        [.command, .control], [.command, .option],
      ] {
        #expect(!RecordTableView.acceptsDuplicate(try event("d", flags: flags)))
      }
      #expect(!RecordTableView.acceptsDuplicate(try event("d", flags: .command, repeated: true)))
      #expect(!RecordTableView.acceptsDuplicate(try event("z", flags: .command)))
      #expect(RecordTableView.acceptsDuplicate(try event("D", flags: [.command, .capsLock])))
    }

    @Test func duplicateDispatchUsesTheExactSelectedLoadedRowAndHonorsDisabledActions() {
      let rows = [
        WorkspaceRow(record: ["id": .string("café")], label: "First"),
        WorkspaceRow(record: ["id": .string("café")], label: "Second"),
      ]
      var copied: [Data] = []
      var grid = MacRecordTable(
        rows: rows, columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in },
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      grid.onDuplicate = {
        copied.append($0.byteExactID)
        return true
      }
      let coordinator = grid.makeCoordinator()
      let table = NSTableView()
      table.addTableColumn(NSTableColumn(identifier: .init("record")))
      table.dataSource = coordinator
      coordinator.table = table
      table.reloadData()
      _ = coordinator.duplicateSelectedRecord()
      #expect(copied.isEmpty)
      table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      _ = coordinator.duplicateSelectedRecord()
      #expect(copied == [rows[1].byteExactID])
      table.allowsMultipleSelection = true
      table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
      #expect(!coordinator.duplicateSelectedRecord())
      #expect(copied == [rows[1].byteExactID])
      table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      grid = MacRecordTable(
        rows: rows, columns: [], titleField: nil, editingRow: nil, editingColumn: nil,
        editorID: nil, actionsEnabled: false, onOpen: { _ in }, onEdit: { _, _ in },
        onSort: { _, _ in }, onFilter: { _ in }, editor: { EmptyView() })
      grid.onDuplicate = {
        copied.append($0.byteExactID)
        return true
      }
      coordinator.parent = grid
      _ = coordinator.duplicateSelectedRecord()
      #expect(copied == [rows[1].byteExactID])
      #expect(table.window == nil)
    }

    @Test func markerUsesTheExactCreatedIDAndOnlyTheTitleCell() {
      let rows = [
        WorkspaceRow(record: ["id": .string("café")], label: "First"),
        WorkspaceRow(record: ["id": .string("cafe\u{301}")], label: "Second"),
      ]
      let title = CatalogField(property: ["col": .string("title")])
      let status = CatalogField(property: ["col": .string("status")])
      var grid = MacRecordTable(
        rows: rows, columns: [NativeGridColumn(field: status, width: 180)], titleField: title,
        editingRow: nil, editingColumn: nil, editorID: nil, actionsEnabled: true,
        onOpen: { _ in }, onEdit: { _, _ in }, onSort: { _, _ in }, onFilter: { _ in },
        editor: { EmptyView() })
      grid.duplicatedRow = rows[1].byteExactID
      let coordinator = grid.makeCoordinator()
      #expect(!coordinator.cell(row: 0, column: 0).duplicated)
      #expect(coordinator.cell(row: 1, column: 0).duplicated)
      #expect(!coordinator.cell(row: 1, column: 1).duplicated)
    }

    private func event(
      _ character: String, flags: NSEvent.ModifierFlags, repeated: Bool = false
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: 0, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: repeated, keyCode: 2))
    }
  }
#endif
