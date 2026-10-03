#if os(macOS)
  import SwiftUI

  @available(macOS 14.4, *)
  struct MacRecordTable: View {
    let rows: [WorkspaceRow]
    let columns: [NativeGridColumn]
    let onOpen: (WorkspaceRow) -> Void
    @State private var selection: Data?

    var body: some View {
      Table(rows.map { NativeGridRow(row: $0) }, selection: $selection) {
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
        TableColumnForEach(columns) { column in
          TableColumn(column.label) { item in
            Text(column.text(in: item.row.record)).lineLimit(1)
              .help(column.text(in: item.row.record))
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
