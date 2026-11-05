#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @MainActor struct MacHeaderMenuTests {
    @Test func aHeaderClickUsesTheExistingMenuAndColumnTarget() throws {
      var sorted: [String] = []
      let (coordinator, table) = fixture { sorted.append("\($0):\($1)") }
      var presented: [(NSMenu, Int)] = []
      coordinator.presentHeaderMenu = { presented.append(($0, $1)) }
      let delegate: NSTableViewDelegate = coordinator

      delegate.tableView?(table, didClick: table.tableColumns[1])

      let (menu, column) = try #require(presented.first)
      #expect(presented.count == 1 && column == 1)
      #expect(menu.items.map(\.title) == coordinator.columnMenu(1)?.items.map(\.title))
      let sort = try #require(menu.items.first { !$0.isSeparatorItem && $0.tag == 0 })
      coordinator.columnAction(sort)
      #expect(sorted == ["status:true"])
      #expect(table.window == nil)
    }

    @Test func detachedColumnsAndAnotherTableCannotPresentAMenu() {
      let (coordinator, table) = fixture { _, _ in }
      var count = 0
      coordinator.presentHeaderMenu = { _, _ in count += 1 }
      let delegate: NSTableViewDelegate = coordinator
      delegate.tableView?(table, didClick: NSTableColumn(identifier: .init("record")))

      let other = NSTableView()
      let column = NSTableColumn(identifier: .init("record"))
      other.addTableColumn(column)
      delegate.tableView?(other, didClick: column)

      #expect(count == 0)
      #expect(table.window == nil && other.window == nil)
    }

    private func fixture(
      onSort: @escaping (String, Bool) -> Void
    ) -> (MacRecordTable<EmptyView>.Coordinator, NSTableView) {
      let title = CatalogField(property: ["col": .string("title"), "label": .string("Title")])
      let status = CatalogField(property: ["col": .string("status"), "label": .string("Status")])
      let view = MacRecordTable(
        rows: [], columns: [NativeGridColumn(field: status, width: 180)], titleField: title,
        editingRow: nil, editingColumn: nil, editorID: nil, actionsEnabled: true,
        onOpen: { _ in }, onEdit: { _, _ in }, onSort: onSort, onFilter: { _ in },
        editor: { EmptyView() })
      let coordinator = view.makeCoordinator()
      let table = NSTableView()
      for id in ["record", "property:status"] {
        table.addTableColumn(NSTableColumn(identifier: .init(id)))
      }
      coordinator.table = table
      table.delegate = coordinator
      return (coordinator, table)
    }
  }
#endif
