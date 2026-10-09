#if os(macOS)
  import AppKit
  import SwiftUI

  /// AppKit owns cell double-clicks and header menus. SwiftUI retains the shared
  /// field controls, validation, and recovery draft inside the selected cell.
  struct MacRecordTable<Editor: View>: NSViewRepresentable {
    let rows: [WorkspaceRow]
    let columns: [NativeGridColumn]
    let titleField: CatalogField?
    let editingRow: Data?
    let editingColumn: String?
    let editorID: UUID?
    let actionsEnabled: Bool
    let onOpen: (WorkspaceRow) -> Void
    let onEdit: (WorkspaceRow, String) -> Void
    let onSort: (String, Bool) -> Void
    let onFilter: (String) -> Void
    var workspace: NativeWorkspace? = nil
    var transport: HubTransport? = nil
    var actions: [CoreRowAction] = []
    var layout: [CoreViewLayoutItem]?
    var canRunAction = false
    var onAction: (String, WorkspaceRow) -> Void = { _, _ in }
    @ViewBuilder let editor: () -> Editor

    private var gridItems: [NativeGridItem] {
      let title =
        titleField ?? CatalogField(property: ["col": .string("id"), "label": .string("Record")])
      return NativeGridItem.items(
        columns: [NativeGridColumn(field: title, width: 240)]
          + columns.filter { Data($0.id.utf8) != Data(title.id.utf8) },
        actions: actions, layout: layout)
    }

    private func isTitle(_ item: NativeGridItem) -> Bool {
      item.column.map { Data($0.id.utf8) == Data((titleField?.id ?? "id").utf8) } ?? false
    }

    private func identifier(_ item: NativeGridItem) -> String {
      if isTitle(item) { return "record" }
      if let action = item.action { return "action:" + action.id }
      return "property:" + item.column!.id
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      let table = RecordTableView()
      table.style = .inset
      table.rowHeight = 28
      table.intercellSpacing = NSSize(width: 12, height: 4)
      table.usesAutomaticRowHeights = false
      table.usesAlternatingRowBackgroundColors = true
      table.columnAutoresizingStyle = .noColumnAutoresizing
      table.dataSource = context.coordinator
      table.delegate = context.coordinator
      table.target = context.coordinator
      table.doubleAction = #selector(Coordinator.editSelectedCell(_:))
      table.editSelection = { [weak coordinator = context.coordinator, weak table] in
        guard let coordinator, let table else { return }
        guard let title = coordinator.items.firstIndex(where: { coordinator.parent.isTitle($0) })
        else { return }
        coordinator.edit(row: table.selectedRow, column: title)
      }
      table.setAccessibilityIdentifier("record-grid")
      table.setAccessibilityLabel("Records")
      context.coordinator.table = table
      let header = RecordTableHeaderView()
      header.makeMenu = { [weak coordinator = context.coordinator] column in
        coordinator?.columnMenu(column)
      }
      table.headerView = header
      let menu = NSMenu()
      menu.autoenablesItems = false
      let open = NSMenuItem(
        title: "Open record", action: #selector(Coordinator.openSelectedRecord(_:)),
        keyEquivalent: "")
      open.target = context.coordinator
      menu.addItem(open)
      table.menu = menu
      scroll.documentView = table
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      guard let table = scroll.documentView as? NSTableView else { return }
      let coordinator = context.coordinator
      let previous = coordinator.parent
      coordinator.parent = self
      coordinator.items = gridItems
      let items = coordinator.items
      table.selectionHighlightStyle = editorID == nil ? .regular : .none
      if previous.editorID != editorID { coordinator.editorHeight = 28 }
      table.menu?.items.first?.isEnabled = actionsEnabled
      let identifiers = items.map(identifier)
      let columnsChanged = table.tableColumns.map { $0.identifier.rawValue } != identifiers
      let rowsChanged = previous.rows.map(\.byteExactID) != rows.map(\.byteExactID)
      let contentChanged =
        previous.rows.map(\.record) != rows.map(\.record)
        || previous.rows.map(\.label) != rows.map(\.label)
        || previous.editorID != editorID || previous.actionsEnabled != actionsEnabled
        || previous.columns.map { $0.field.property } != columns.map { $0.field.property }
        || previous.titleField?.property != titleField?.property
        || previous.actions != actions || previous.canRunAction != canRunAction
      guard columnsChanged || rowsChanged || contentChanged else { return }
      let selected =
        previous.rows.indices.contains(table.selectedRow)
        ? previous.rows[table.selectedRow].byteExactID : nil
      if columnsChanged {
        // Clear row views before changing column structure so AppKit does not
        // reuse constraints attached to removed cells.
        table.dataSource = nil
        table.reloadData()
        for column in table.tableColumns { table.removeTableColumn(column) }
        for (index, id) in identifiers.enumerated() {
          let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
          column.title = items[index].label
          column.minWidth = isTitle(items[index]) ? 180 : 96
          column.maxWidth = 800
          column.width = items[index].width
          table.addTableColumn(column)
        }
        table.dataSource = coordinator
      }
      for (index, column) in table.tableColumns.enumerated() {
        column.title = items[index].label
      }
      if columnsChanged || rowsChanged {
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.byteExactID == selected }) {
          table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
      } else {
        // Replacing existing roots preserves an active field's focus and draft.
        for row in rows.indices {
          for column in table.tableColumns.indices {
            if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false),
              let host = cell.subviews.first as? NSHostingView<MacRecordCell<Editor>>
            {
              host.rootView = coordinator.cell(row: row, column: column)
            }
          }
        }
      }
      table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
      if editorID != nil, previous.editorID != editorID,
        let column = table.tableColumns.firstIndex(where: {
          $0.identifier.rawValue == "property:" + (editingColumn ?? "")
        })
      {
        table.scrollColumnToVisible(column)
      }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
      var parent: MacRecordTable
      weak var table: NSTableView?
      var editorHeight: CGFloat = 28
      var items: [NativeGridItem]
      init(_ parent: MacRecordTable) {
        self.parent = parent
        items = parent.gridItems
      }
      func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
      func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        parent.rows.indices.contains(row) && parent.rows[row].byteExactID == parent.editingRow
          ? editorHeight : 28
      }
      func resizeEditor(_ height: CGFloat, id: UUID?) {
        // SwiftUI measures its content after the representable update. Apply the
        // measured height on the next turn so AppKit never clips that content.
        Task { @MainActor [weak self] in
          guard let self, id == parent.editorID,
            let row = parent.rows.firstIndex(where: {
              $0.byteExactID == parent.editingRow
            })
          else { return }
          let next = max(28, ceil(height))
          guard abs(editorHeight - next) > 0.5 else { return }
          editorHeight = next
          table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
      }

      func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
      {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn),
          parent.rows.indices.contains(row)
        else { return nil }
        let view = NSTableCellView()
        let host = NSHostingView(rootView: cell(row: row, column: column))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
          host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
          host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
          host.topAnchor.constraint(equalTo: view.topAnchor),
          host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
          view.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        return view
      }

      fileprivate func cell(row: Int, column: Int) -> MacRecordCell<Editor> {
        let columnItem = items[column]
        let title = parent.isTitle(columnItem)
        let field = title ? parent.titleField : columnItem.column?.field
        let item = parent.rows[row]
        return MacRecordCell(
          row: item, field: field, isTitle: title,
          action: columnItem.action, canRunAction: parent.canRunAction, onAction: parent.onAction,
          editing: item.byteExactID == parent.editingRow && field?.id == parent.editingColumn,
          editorID: parent.editorID, actionsEnabled: parent.actionsEnabled,
          onOpen: parent.onOpen, workspace: parent.workspace, transport: parent.transport,
          onHeight: { [weak self, id = parent.editorID] height in
            self?.resizeEditor(height, id: id)
          }, editor: parent.editor())
      }

      @objc func editSelectedCell(_ table: NSTableView) {
        let row = table.clickedRow
        let column = table.clickedColumn >= 0 ? table.clickedColumn : 0
        edit(row: row, column: column)
      }

      func edit(row: Int, column: Int) {
        guard parent.actionsEnabled, parent.rows.indices.contains(row),
          items.indices.contains(column), items[column].action == nil
        else { return }
        let field = parent.isTitle(items[column]) ? parent.titleField : items[column].column?.field
        if let field {
          parent.onEdit(parent.rows[row], field.id)
        } else {
          parent.onOpen(parent.rows[row])
        }
      }

      @objc func openSelectedRecord(_ sender: NSMenuItem) {
        guard parent.actionsEnabled, let table,
          parent.rows.indices.contains(table.selectedRow)
        else { return }
        parent.onOpen(parent.rows[table.selectedRow])
      }

      func columnMenu(_ column: Int) -> NSMenu? {
        guard items.indices.contains(column), items[column].action == nil else { return nil }
        let field = parent.isTitle(items[column]) ? parent.titleField : items[column].column?.field
        guard let field else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (tag, title) in ["Sort ascending", "Sort descending", "Filter…"].enumerated() {
          let item = NSMenuItem(
            title: title, action: #selector(columnAction(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = field.id
          item.tag = tag
          item.isEnabled = parent.actionsEnabled
          menu.addItem(item)
        }
        return menu
      }

      @objc private func columnAction(_ item: NSMenuItem) {
        guard parent.actionsEnabled, let id = item.representedObject as? String else { return }
        if item.tag == 2 { parent.onFilter(id) } else { parent.onSort(id, item.tag == 0) }
      }
    }
  }

  private struct MacRecordCell<Editor: View>: View {
    let row: WorkspaceRow
    let field: CatalogField?
    let isTitle: Bool
    let action: CoreRowAction?
    let canRunAction: Bool
    let onAction: (String, WorkspaceRow) -> Void
    let editing: Bool
    let editorID: UUID?
    let actionsEnabled: Bool
    let onOpen: (WorkspaceRow) -> Void
    let workspace: NativeWorkspace?
    let transport: HubTransport?
    let onHeight: (CGFloat) -> Void
    let editor: Editor

    var body: some View {
      Group {
        if editing {
          editor.id(editorID).padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: {
              onHeight($0)
            }
        } else if let action {
          Button(action.label) { onAction(action.id, row) }
            .buttonStyle(.borderless)
            .disabled(!actionsEnabled || !canRunAction)
            .accessibilityIdentifier("row-action-" + action.id)
        } else {
          HStack(spacing: 6) {
            Group {
              if isTitle {
                Text(row.label)
              } else if let field {
                NativePropertyValue(
                  field: field, value: field.formValue(row.record[field.id]),
                  workspace: workspace, transport: transport, imageSize: 20)
              }
            }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if isTitle {
              Button {
                onOpen(row)
              } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
              }.buttonStyle(.borderless)
                .accessibilityLabel("Open " + row.label)
                .accessibilityIdentifier("grid-open-" + row.id)
                .disabled(!actionsEnabled)
            }
          }
        }
      }
      .padding(.top, editing ? 0 : 6)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private final class RecordTableView: NSTableView {
    var editSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
      if event.charactersIgnoringModifiers == "\r" {
        editSelection?()
      } else {
        super.keyDown(with: event)
      }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
      let row = row(at: convert(event.locationInWindow, from: nil))
      guard row >= 0 else { return nil }
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      return super.menu(for: event)
    }
  }

  private final class RecordTableHeaderView: NSTableHeaderView {
    var makeMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
      makeMenu?(column(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let column = column(at: point)
      guard column >= 0, abs(headerRect(ofColumn: column).maxX - point.x) > 5,
        abs(headerRect(ofColumn: column).minX - point.x) > 5,
        let menu = menu(for: event)
      else {
        super.mouseDown(with: event)
        return
      }
      menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: bounds.maxY), in: self)
    }
  }
#endif
