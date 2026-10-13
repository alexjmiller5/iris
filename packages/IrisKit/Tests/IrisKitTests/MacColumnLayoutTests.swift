#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  @testable import IrisKit

  @MainActor struct MacColumnLayoutTests {
    @Test func headerControlsPersistLayoutAndDoubleClickFitsTheColumn() async throws {
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil))
      await model.open(demo: true)
      _ = NSApplication.shared
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
      }
      for _ in 0..<100
      where !descendants(host).contains(where: {
        ($0 as? NSTableView)?.numberOfColumns ?? 0 > 1
      }) { try await Task.sleep(for: .milliseconds(20)) }
      let table = try #require(
        descendants(host).compactMap { $0 as? NSTableView }.first {
          $0.numberOfColumns > 1
        })
      let status = try #require(table.tableColumns.firstIndex { $0.title == "Status" })
      table.moveColumn(status, toColumn: 0)
      #expect(model.viewLayout?.first?.id == "status")
      table.tableColumns[0].width = 410
      #expect(model.columnWidths["status"] == 410)
      await model.flushViewSave()
      #expect(model.appliedView?.definition?.widths?["status"] == 410)
      try await Task.sleep(for: .milliseconds(100))
      let fittedTable = try #require(
        descendants(host).compactMap { $0 as? NSTableView }.first {
          $0.numberOfColumns > 1
        })
      let index = try #require(fittedTable.tableColumns.firstIndex { $0.title == "Status" })
      let header = try #require(fittedTable.headerView)
      let rect = header.headerRect(ofColumn: index)
      let point = header.convert(NSPoint(x: rect.maxX - 1, y: rect.midY), to: nil)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: point,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2,
          pressure: 1))
      header.mouseDown(with: event)
      for _ in 0..<100 where model.columnWidths["status"] == 410 {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(try #require(model.columnWidths["status"]) < 410)
      await model.flushViewSave()
      #expect(model.appliedView?.definition?.widths?["status"] == model.columnWidths["status"])
      await model.close()
    }

    @Test func unchangedColumnsRestoreDefaultWidthsWhenSavedWidthsAreCleared() async throws {
      let field = CatalogField(property: ["col": .string("title"), "label": .string("Title")])
      func grid(_ widths: [String: Double]) -> MacRecordTable<EmptyView> {
        MacRecordTable(
          rows: [], columns: [], titleField: field, editingRow: nil,
          editingColumn: nil, editorID: nil, actionsEnabled: true, onOpen: { _ in },
          onEdit: { _, _ in }, onSort: { _, _ in }, onFilter: { _ in }, columnWidths: widths,
          editor: { EmptyView() }
        )
      }
      _ = NSApplication.shared
      let host = NSHostingView(rootView: grid(["title": 410]))
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      for _ in 0..<100
      where !descendants(host).contains(where: { ($0 as? NSTableView)?.numberOfColumns == 1 }) {
        try await Task.sleep(for: .milliseconds(20))
      }
      let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
      #expect(table.tableColumns[0].width == 410)
      host.rootView = grid([:])
      for _ in 0..<100 where table.tableColumns[0].width != 240 {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(table.tableColumns[0].width == 240)
    }

    @Test func nativeReorderAndResizeKeepCellAndMenuIdentities() throws {
      let title = CatalogField(property: ["col": .string("title"), "label": .string("Title")])
      let status = CatalogField(property: ["col": .string("status"), "label": .string("Status")])
      let hidden = CatalogField(property: ["col": .string("body"), "label": .string("Body")])
      var order: [CoreViewLayoutItem] = []
      var widths: [String: Double] = [:]
      var visibility: [String: Bool] = [:]
      var edited: String?
      let grid = MacRecordTable(
        rows: [WorkspaceRow(record: ["id": .string("row")], label: "Row")],
        columns: [NativeGridColumn(field: status, width: 180)], titleField: title,
        editingRow: nil, editingColumn: nil, editorID: nil, actionsEnabled: true,
        onOpen: { _ in }, onEdit: { _, id in edited = id }, onSort: { _, _ in },
        onFilter: { _ in }, availableFields: [title, status, hidden],
        onColumnVisibility: { visibility[$0] = $1 }, onColumnOrder: { order = $0 },
        onColumnWidth: { widths[$0] = $1 }, editor: { EmptyView() }
      )
      let coordinator = grid.makeCoordinator()
      let table = NSTableView()
      for id in ["record", "property:status"] {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)))
      }
      coordinator.table = table
      table.moveColumn(1, toColumn: 0)
      coordinator.tableViewColumnDidMove(
        Notification(name: NSTableView.columnDidMoveNotification, object: table))
      #expect(order.map(\.id) == ["status", "title"])
      coordinator.edit(row: 0, column: 0)
      #expect(edited == "status")
      #expect(coordinator.columnMenu(0)?.items.first?.representedObject as? String == "status")
      table.tableColumns[0].width = 333
      coordinator.tableViewColumnDidResize(
        Notification(name: NSTableView.columnDidResizeNotification, object: table))
      #expect(widths["status"] == 333)
      let menu = try #require(coordinator.columnMenu(0))
      let show = try #require(menu.items.first { $0.title == "Show columns" }?.submenu)
      let body = try #require(show.items.first { $0.title == "Body" })
      #expect(body.state == .off)
      coordinator.columnAction(body)
      #expect(visibility["body"] == true)
      let hide = try #require(menu.items.first { $0.title == "Hide column" })
      coordinator.columnAction(hide)
      #expect(visibility["status"] == false)
    }
  }
#endif
