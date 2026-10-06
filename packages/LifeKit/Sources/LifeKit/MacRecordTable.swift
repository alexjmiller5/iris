#if os(macOS)
  import SwiftUI

  @available(macOS 14.4, *)
  struct MacRecordTable: View {
    let rows: [WorkspaceRow]
    let columns: [NativeGridColumn]
    var displayColumn = "id"
    var actions: [CoreRowAction] = []
    var layout: [CoreViewLayoutItem]?
    var canRunAction = false
    var onAction: (String, WorkspaceRow) -> Void = { _, _ in }
    let onOpen: (WorkspaceRow) -> Void
    @State private var selection: Data?

    var body: some View {
      Table(rows.map { NativeGridRow(row: $0) }, selection: $selection) {
        if layout == nil || !columns.contains(where: { $0.id == displayColumn }) {
          TableColumn("Record") { item in
            Button {
              onOpen(item.row)
            } label: {
              Text(item.row.label).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open " + item.row.label)
            .accessibilityIdentifier("grid-open-" + item.row.id)
          }.width(min: 180, ideal: 240, max: 480)
        }
        TableColumnForEach(NativeGridItem.items(columns: columns, actions: actions, layout: layout))
        { column in
          TableColumn(column.label) { item in
            if let action = column.action {
              Button(action.label) { onAction(action.id, item.row) }.disabled(!canRunAction)
            } else if let field = column.column {
              if layout != nil && field.id == displayColumn {
                Button(item.row.label) { onOpen(item.row) }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Open " + item.row.label)
                  .accessibilityIdentifier("grid-open-" + item.row.id)
              } else {
                Text(field.text(in: item.row.record)).lineLimit(1).help(
                  field.text(in: item.row.record))
              }
            }
          }.width(min: 96, ideal: column.width, max: 800)
        }
      }
      .accessibilityIdentifier("record-grid")
      .contextMenu(forSelectionType: Data.self) { ids in
        if let row = NativeGridRow.selected(in: rows, ids: ids) {
          Button("Open record") { onOpen(row) }
        }
      } primaryAction: { ids in
        if let row = NativeGridRow.selected(in: rows, ids: ids) { onOpen(row) }
      }
    }

  }
#endif
