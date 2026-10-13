#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import IrisKit

  @Suite(.serialized) @MainActor
  struct MacInlineEditingTests {
    @Test func actionColumnsKeepPropertyEditingAndHeaderTargets() {
      let title = CatalogField(property: ["col": .string("title")])
      let status = CatalogField(property: ["col": .string("status")])
      let row = WorkspaceRow(record: ["id": .string("row")], label: "Row")
      var edited: [String] = []
      var opened = false
      let grid = MacRecordTable(
        rows: [row], columns: [NativeGridColumn(field: status, width: 180)],
        titleField: title, editingRow: nil, editingColumn: nil, editorID: nil,
        actionsEnabled: true, onOpen: { _ in opened = true },
        onEdit: { _, column in edited.append(column) }, onSort: { _, _ in }, onFilter: { _ in },
        actions: [
          CoreRowAction(id: "review", label: "Review", values: ["status": .string("Ready")])
        ],
        layout: [
          CoreViewLayoutItem(kind: "column", id: "status"),
          CoreViewLayoutItem(kind: "action", id: "review"),
          CoreViewLayoutItem(kind: "column", id: "title"),
        ], canRunAction: true
      ) { EmptyView() }
      let coordinator = grid.makeCoordinator()
      coordinator.edit(row: 0, column: 0)
      coordinator.edit(row: 0, column: 1)
      coordinator.edit(row: 0, column: 2)
      #expect(edited == ["status", "title"])
      #expect(!opened)
      #expect(coordinator.columnMenu(0)?.items.first?.representedObject as? String == "status")
      #expect(coordinator.columnMenu(1) == nil)
      #expect(coordinator.columnMenu(2)?.items.first?.representedObject as? String == "title")
    }

    @Test func returnEditsTheSelectedTitleWithoutOpeningASheet() async throws {
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil))
      await model.open(demo: true)
      defer { Task { await model.close() } }
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      for _ in 0..<100
      where !descendants(host).contains(where: {
        guard let table = $0 as? NSTableView else { return false }
        return table.numberOfColumns > 1 && table.numberOfRows > 0
      }) { try await Task.sleep(for: .milliseconds(20)) }
      let table = try #require(
        descendants(host).compactMap { $0 as? NSTableView }.first {
          $0.numberOfColumns > 1 && $0.numberOfRows > 0
        })
      try #require(table.numberOfRows > 0)
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      let key = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "\r",
          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
      table.keyDown(with: key)
      for _ in 0..<100
      where !hasTitleField(window)
        && window.sheets.isEmpty
      { try await Task.sleep(for: .milliseconds(20)) }
      #expect(window.sheets.isEmpty, "Cell editing must not open a record sheet")
      #expect(hasTitleField(window))
      let catalog = try #require(model.catalog)
      model.catalog = try WorkspaceCatalog(
        CoreCatalog(
          tables: catalog.tables,
          properties: [], rules: catalog.rules))
      try await Task.sleep(for: .milliseconds(100))
      let retained = try #require(
        table.tableColumns.firstIndex { $0.identifier.rawValue == "property:title" })
      #expect(retained >= 0)
      #expect(
        !(window.childWindows ?? []).isEmpty, "Catalog changes must preserve the open cell editor")
      #expect(table.action != nil)

    }

    @Test func columnHeaderProvidesSortAndFilterActions() async throws {
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil))
      await model.open(demo: true)
      defer { Task { await model.close() } }
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      for _ in 0..<100
      where !descendants(host).contains(where: {
        ($0 as? NSTableView).map { $0.numberOfColumns > 1 && $0.numberOfRows > 0 } ?? false
      }) { try await Task.sleep(for: .milliseconds(20)) }
      let table = try #require(
        descendants(host).compactMap { $0 as? NSTableView }.first {
          $0.numberOfColumns > 1 && $0.numberOfRows > 0
        })
      let header = try #require(table.headerView)
      let column = try #require(table.tableColumns.firstIndex { $0.title == "Title" })
      let rect = header.headerRect(ofColumn: column)
      let point = header.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: point,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
          pressure: 1))
      let menu = try #require(header.menu(for: event))
      #expect(menu.items.map(\.title).contains("Sort ascending"))
      #expect(menu.items.map(\.title).contains("Sort descending"))
      #expect(menu.items.map(\.title).contains("Filter…"))
      menu.performActionForItem(
        at: try #require(menu.items.firstIndex { $0.title == "Sort descending" }))
      #expect(model.sortColumn == "title")
      #expect(!model.sortAscending)
    }

    @Test func catalogLabelRefreshUpdatesExistingColumnHeaders() async throws {
      let field = CatalogField(property: [
        "col": .string("title"), "label": .string("Title"), "type": .string("text"),
      ])
      func grid(_ title: CatalogField) -> MacRecordTable<EmptyView> {
        MacRecordTable(
          rows: [
            WorkspaceRow(
              record: ["id": .string("one"), "title": .string("Example")], label: "Example")
          ],
          columns: [], titleField: title, editingRow: nil, editingColumn: nil, editorID: nil,
          actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in }, onSort: { _, _ in },
          onFilter: { _ in }
        ) { EmptyView() }
      }
      let host = NSHostingView(rootView: grid(field))
      host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      for _ in 0..<100
      where descendants(host).compactMap({ $0 as? NSTableView }).first?.numberOfColumns != 1 {
        try await Task.sleep(for: .milliseconds(20))
      }
      let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
      #expect(table.tableColumns.first?.title == "Title")
      host.rootView = grid(
        CatalogField(property: [
          "col": .string("title"), "label": .string("Name"), "type": .string("text"),
        ]))
      for _ in 0..<100 where table.tableColumns.first?.title != "Name" {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(table.tableColumns.first?.title == "Name")
    }

    @Test func scrollingReusesCellHostsForTheRowsScrolledIn() async throws {
      func field(_ id: String) -> CatalogField {
        CatalogField(property: [
          "col": .string(id), "label": .string(id.capitalized), "type": .string("text"),
        ])
      }
      let rows = (0..<300).map { index in
        WorkspaceRow(
          record: [
            "id": .string("row-\(index)"), "title": .string("Row \(index)"),
            "body": .string("Body \(index)"),
          ], label: "Row \(index)")
      }
      let host = NSHostingView(
        rootView: MacRecordTable(
          rows: rows, columns: [NativeGridColumn(field: field("body"), width: 180)],
          titleField: field("title"), editingRow: nil, editingColumn: nil, editorID: nil,
          actionsEnabled: true, onOpen: { _ in }, onEdit: { _, _ in }, onSort: { _, _ in },
          onFilter: { _ in }
        ) { EmptyView() })
      host.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      for _ in 0..<100
      where descendants(host).compactMap({ $0 as? NSTableView }).first?.numberOfRows != 300 {
        try await Task.sleep(for: .milliseconds(20))
      }
      let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
      typealias Cell = NSHostingView<MacRecordCell>
      func visibleCells() -> [(row: Int, host: Cell)] {
        let range = table.rows(in: table.visibleRect)
        return (range.lowerBound..<range.upperBound).flatMap { row in
          table.tableColumns.indices.compactMap { column in
            (table.view(atColumn: column, row: row, makeIfNecessary: false)?.subviews.first
              as? Cell).map { (row, $0) }
          }
        }
      }
      // Retained, so no two hosts can share an identity.
      var seen: [Cell] = []
      let started = ContinuousClock.now
      for row in stride(from: 0, to: 300, by: 4) {
        table.scrollRowToVisible(row)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        seen += visibleCells().map(\.host)
      }
      let elapsed = started.duration(to: .now)
      let created = Set(seen.map(ObjectIdentifier.init)).count
      print("macGridScroll rows=300 columns=2 hosts_created=\(created) elapsed=\(elapsed)")
      #expect(!seen.isEmpty)
      #expect(created < 120, "300 rows x 2 columns scrolled through must reuse cell hosts")
      // A reused host shows the row it was handed, not the one it showed before.
      for (row, cell) in visibleCells() {
        #expect(cell.rootView.row.id == "row-\(row)")
      }
    }

    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }

    private func hasTitleField(_ window: NSWindow) -> Bool {
      ([window] + (window.childWindows ?? [])).compactMap(\.contentView).flatMap(descendants)
        .contains {
          ($0 as? NSTextField).map { $0.isEditable && $0.stringValue == "A place to start" }
            ?? false
        }
    }
  }
#endif
