#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import LifeKit

  @Suite(.serialized) @MainActor
  struct MacInlineEditingTests {
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
      where !hasTitleField(table)
        && window.sheets.isEmpty
      { try await Task.sleep(for: .milliseconds(20)) }
      #expect(window.sheets.isEmpty, "Double-click must keep editing inside the grid")
      #expect(hasTitleField(table))
      let catalog = try #require(model.catalog)
      model.catalog = try WorkspaceCatalog(
        CoreCatalog(
          tables: catalog.tables,
          properties: [], rules: catalog.rules))
      try await Task.sleep(for: .milliseconds(100))
      let retained = try #require(
        table.tableColumns.firstIndex { $0.identifier.rawValue == "property:title" })
      let cell = try #require(table.view(atColumn: retained, row: 0, makeIfNecessary: true))
      #expect(
        cell.fittingSize.height > 44,
        "The retained cell must include the inline editor's action row")

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

    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }

    private func hasTitleField(_ table: NSTableView) -> Bool {
      descendants(table).contains {
        ($0 as? NSTextField).map { $0.isEditable && $0.stringValue == "A place to start" } ?? false
      }
    }
  }
#endif
