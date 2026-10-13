#if os(macOS)
  import AppKit
  import SwiftUI

  /// AppKit owns cell clicks and header menus. SwiftUI retains the shared
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
    var onDismissEditor: () -> Void = {}
    let onSort: (String, Bool) -> Void
    let onFilter: (String) -> Void
    var workspace: NativeWorkspace? = nil
    var transport: HubTransport? = nil
    var actions: [CoreRowAction] = []
    var layout: [CoreViewLayoutItem]?
    var canRunAction = false
    var onAction: (String, WorkspaceRow) -> Void = { _, _ in }
    /// Property IDs whose cells wrap their whole value; their rows grow to fit.
    var wrapped: Set<String> = []
    var onWrap: (String, Bool) -> Void = { _, _ in }
    var availableFields: [CatalogField] = []
    var columnWidths: [String: Double] = [:]
    var onColumnVisibility: (String, Bool) -> Void = { _, _ in }
    var onColumnOrder: ([CoreViewLayoutItem]) -> Void = { _ in }
    var onColumnWidth: (String, Double) -> Void = { _, _ in }
    var onActionColumnWidth: (String, Double) -> Void = { _, _ in }
    var onFitColumn: ((CatalogField) async throws -> Double)?
    @ViewBuilder let editor: () -> Editor

    private var gridItems: [NativeGridItem] {
      let title =
        titleField ?? CatalogField(property: ["col": .string("id"), "label": .string("Record")])
      return NativeGridItem.items(
        columns: [NativeGridColumn(field: title, width: columnWidths[title.id] ?? 240)]
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
      table.didAttach = { [weak coordinator = context.coordinator] in coordinator?.updateEditor() }
      table.style = .inset
      table.rowHeight = 28
      table.intercellSpacing = NSSize(width: 12, height: 4)
      table.usesAutomaticRowHeights = false
      table.usesAlternatingRowBackgroundColors = true
      table.allowsColumnReordering = true
      table.allowsColumnResizing = true
      table.columnAutoresizingStyle = .noColumnAutoresizing
      table.dataSource = context.coordinator
      table.delegate = context.coordinator
      table.target = context.coordinator
      table.action = #selector(Coordinator.editSelectedCell(_:))
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
      header.fitColumn = { [weak coordinator = context.coordinator] index in
        Task { await coordinator?.fitColumn(index) }
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
      coordinator.applyingColumns = true
      defer { coordinator.applyingColumns = false }
      coordinator.parent = self
      coordinator.items = gridItems
      let items = coordinator.items
      table.selectionHighlightStyle = editorID == nil ? .regular : .none
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
        || previous.wrapped != wrapped
        || previous.columnWidths != columnWidths
        || previous.layout != layout
        || previous.columns.map(\.width) != columns.map(\.width)
      if previous.wrapped != wrapped || columnsChanged { coordinator.wrapHeights = [:] }
      guard columnsChanged || rowsChanged || contentChanged else {
        coordinator.updateEditor()
        return
      }
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
          column.minWidth = isTitle(items[index]) ? 100 : 48
          column.maxWidth = .greatestFiniteMagnitude
          column.width = items[index].width
          table.addTableColumn(column)
        }
        table.dataSource = coordinator
      }
      for (index, column) in table.tableColumns.enumerated() {
        column.title = items[index].label
        if abs(column.width - items[index].width) > 0.5 { column.width = items[index].width }
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
              let host = cell.subviews.first as? NSHostingView<MacRecordCell>
            {
              host.rootView = coordinator.cell(row: row, column: column)
            }
          }
        }
      }
      table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
      coordinator.updateEditor()
      if editorID != nil, previous.editorID != editorID,
        let column = table.tableColumns.firstIndex(where: {
          $0.identifier.rawValue == "property:" + (editingColumn ?? "")
        })
      {
        table.scrollColumnToVisible(column)
      }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
      coordinator.closeEditor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate
    {
      var parent: MacRecordTable
      private let popover = NSPopover()
      private var editorHost: NSHostingController<MacCellEditor<Editor>>?
      private var presentedEditorID: UUID?
      private var outsideClickMonitor: Any?

      func popoverShouldClose(_ popover: NSPopover) -> Bool {
        parent.onDismissEditor()
        return false  // Flush pending input through the shared editor before closing.
      }

      func closeEditor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        popover.close()
        popover.contentViewController = nil
        editorHost = nil
        presentedEditorID = nil
      }

      func updateEditor() {
        guard let id = parent.editorID, parent.editingColumn != nil else {
          closeEditor()
          return
        }
        let content = MacCellEditor(content: parent.editor())
        if presentedEditorID == id, let editorHost {
          editorHost.rootView = content
          return
        }
        guard let table, table.window != nil,
          let row = parent.rows.firstIndex(where: { $0.byteExactID == parent.editingRow }),
          let column = items.firstIndex(where: { $0.column?.id == parent.editingColumn })
        else { return }
        closeEditor()
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        editorHost = host
        presentedEditorID = id
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        // Table ownership keeps the live editor stable through row recycling.
        popover.show(
          relativeTo: table.frameOfCell(atColumn: column, row: row), of: table, preferredEdge: .maxY
        )
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
          .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) {
          [weak self] event in
          guard let self, let editorWindow = self.editorHost?.view.window else { return event }
          // Child windows include native pickers and property-help popovers.
          var window = event.window
          while let candidate = window {
            if candidate === editorWindow { return event }
            window = candidate.parent
          }
          self.parent.onDismissEditor()
          return nil  // Dismiss only; the underlying control must not receive this click.
        }
      }
      weak var table: NSTableView?
      /// Measured heights of wrapped cells by row and property.
      var wrapHeights: [Data: [String: CGFloat]] = [:]
      var applyingColumns = false
      var items: [NativeGridItem]
      init(_ parent: MacRecordTable) {
        self.parent = parent
        items = parent.gridItems
      }
      func tableViewColumnDidMove(_ notification: Notification) {
        guard !applyingColumns, let table = notification.object as? NSTableView else { return }
        let reordered = table.tableColumns.compactMap { column in
          items.first { parent.identifier($0) == column.identifier.rawValue }
        }
        guard reordered.count == items.count else { return }
        items = reordered
        parent.onColumnOrder(
          items.map {
            CoreViewLayoutItem(
              kind: $0.action == nil ? "column" : "action", id: $0.action?.id ?? $0.column!.id)
          })
        wrapHeights = [:]
        table.reloadData()
        updateEditor()
      }

      func tableViewColumnDidResize(_ notification: Notification) {
        guard !applyingColumns, let table = notification.object as? NSTableView else { return }
        for column in table.tableColumns {
          guard
            let item = items.first(where: { parent.identifier($0) == column.identifier.rawValue })
          else { continue }
          if let action = item.action {
            if abs(item.width - column.width) > 0.5 {
              parent.onActionColumnWidth(action.id, column.width)
            }
          } else if let field = item.column?.field,
            abs((parent.columnWidths[field.id] ?? item.width) - column.width) > 0.5
          {
            parent.onColumnWidth(field.id, column.width)
          }
        }
      }

      func fitColumn(_ index: Int) async {
        guard items.indices.contains(index), let table else { return }
        if let action = items[index].action {
          let width =
            (action.label as NSString).size(withAttributes: [
              .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]).width + 32
          table.tableColumns[index].width = max(table.tableColumns[index].minWidth, ceil(width))
          parent.onActionColumnWidth(action.id, table.tableColumns[index].width)
          return
        }
        guard let field = items[index].column?.field,
          let fit = parent.onFitColumn
        else { return }
        let workspace = parent.workspace
        do {
          let width = try await fit(field)
          guard parent.workspace === workspace,
            let column = table.tableColumns.first(where: { column in
              items.first(where: { parent.identifier($0) == column.identifier.rawValue })?.column?
                .id == field.id
            })
          else { return }
          column.width = max(column.minWidth, width)
          parent.onColumnWidth(field.id, column.width)
        } catch is CancellationError { return } catch {
          // The host reports a read failure; leave the existing width intact.
          return
        }
      }

      func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
      func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard parent.rows.indices.contains(row) else { return 28 }
        let id = parent.rows[row].byteExactID
        let wrapped = wrapHeights[id]?.filter { parent.wrapped.contains($0.key) }.values.max() ?? 0
        // Cells start 6 points down; keep the same space below the tallest wrapped value.
        return max(28, ceil(wrapped) + 12)
      }
      func resizeWrapped(_ height: CGFloat, row: Data, column: String) {
        // Measured after the representable update, like the editor height.
        Task { @MainActor [weak self] in
          guard let self, parent.wrapped.contains(column),
            let index = parent.rows.firstIndex(where: { $0.byteExactID == row }),
            abs((wrapHeights[row]?[column] ?? 0) - height) > 0.5
          else { return }
          wrapHeights[row, default: [:]][column] = height
          table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
      }
      func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
      {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn),
          parent.rows.indices.contains(row)
        else { return nil }
        // A cell scrolled out serves the row scrolled in: a new root costs about a third of
        // a new hosting view. The root's row identity keeps SwiftUI state per row.
        if let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil),
          let host = view.subviews.first as? NSHostingView<MacRecordCell>
        {
          host.rootView = cell(row: row, column: column)
          return view
        }
        let view = NSTableCellView()
        view.identifier = tableColumn.identifier
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

      fileprivate func cell(row: Int, column: Int) -> MacRecordCell {
        let columnItem = items[column]
        let title = parent.isTitle(columnItem)
        let field = title ? parent.titleField : columnItem.column?.field
        let item = parent.rows[row]
        let wraps = field.map { parent.wrapped.contains($0.id) } ?? false
        return MacRecordCell(
          row: item, field: field, isTitle: title, wraps: wraps,
          onWrapHeight: { [weak self, id = item.byteExactID, column = field?.id ?? ""] height in
            self?.resizeWrapped(height, row: id, column: column)
          },
          action: columnItem.action, canRunAction: parent.canRunAction, onAction: parent.onAction,
          actionsEnabled: parent.actionsEnabled,
          onOpen: parent.onOpen, workspace: parent.workspace, transport: parent.transport)
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
        for (tag, title) in ["Sort ascending", "Sort descending", "Filter…", "Wrap text"]
          .enumerated()
        {
          if tag == 3 { menu.addItem(.separator()) }
          let item = NSMenuItem(
            title: title, action: #selector(columnAction(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = field.id
          item.tag = tag
          item.isEnabled = parent.actionsEnabled
          if tag == 3 { item.state = parent.wrapped.contains(field.id) ? .on : .off }
          menu.addItem(item)
        }
        menu.addItem(.separator())
        if !parent.isTitle(items[column]) {
          let hide = NSMenuItem(
            title: "Hide column", action: #selector(columnAction(_:)), keyEquivalent: "")
          hide.target = self
          hide.representedObject = field.id
          hide.tag = 4
          hide.isEnabled = parent.actionsEnabled
          menu.addItem(hide)
        }
        let show = NSMenuItem(title: "Show columns", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for candidate in parent.availableFields {
          let item = NSMenuItem(
            title: candidate.label, action: #selector(columnAction(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = candidate.id
          item.tag = 5
          item.state = items.contains(where: { $0.column?.id == candidate.id }) ? .on : .off
          item.isEnabled = parent.actionsEnabled && candidate.id != parent.titleField?.id
          submenu.addItem(item)
        }
        show.submenu = submenu
        menu.addItem(show)
        return menu
      }

      @objc func columnAction(_ item: NSMenuItem) {
        guard parent.actionsEnabled, let id = item.representedObject as? String else { return }
        switch item.tag {
        case 2: parent.onFilter(id)
        case 3: parent.onWrap(id, !parent.wrapped.contains(id))
        case 4: parent.onColumnVisibility(id, false)
        case 5: parent.onColumnVisibility(id, item.state != .on)
        default: parent.onSort(id, item.tag == 0)
        }
      }
    }
  }

  private struct MacCellEditor<Content: View>: View {
    let content: Content
    var body: some View {
      content.padding(10).frame(width: 340).fixedSize(horizontal: false, vertical: true)
    }
  }

  struct MacRecordCell: View {
    let row: WorkspaceRow
    let field: CatalogField?
    let isTitle: Bool
    let wraps: Bool
    let onWrapHeight: (CGFloat) -> Void
    let action: CoreRowAction?
    let canRunAction: Bool
    let onAction: (String, WorkspaceRow) -> Void
    let actionsEnabled: Bool
    let onOpen: (WorkspaceRow) -> Void
    let workspace: NativeWorkspace?
    let transport: HubTransport?

    var body: some View {
      Group {
        if let action {
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
                let value = field.formValue(row.record[field.id])
                NativePropertyValue(
                  field: field, value: value, workspace: workspace, transport: transport,
                  imageSize: 20
                )
                .accessibilityElement(children: .combine)
                .emptyValueAccessibility(NativePropertyValue.isEmpty(value))
              }
            }
            .lineLimit(wraps ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: wraps)
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: {
              if wraps { onWrapHeight($0) }
            }
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
      .padding(.top, 6)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .id(row.byteExactID)
    }
  }

  private final class RecordTableView: NSTableView {
    var didAttach: (() -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { DispatchQueue.main.async { [weak self] in self?.didAttach?() } }
    }

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
    var fitColumn: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if event.clickCount == 2, let tableView {
        for index in tableView.tableColumns.indices
        where abs(headerRect(ofColumn: index).maxX - point.x) <= 5 {
          fitColumn?(index)
          return
        }
      }
      super.mouseDown(with: event)
    }
  }
#endif
