import Foundation

struct NativeGridColumn: Identifiable {
  let field: CatalogField
  let width: Double
  var id: String { field.id }
  var label: String { field.label }

  static func columns(
    properties: [WorkspaceRecord], selected: [String]? = nil,
    widths: [String: Double] = [:]
  ) -> [Self] {
    let fields = properties.map(CatalogField.init)
    var seen = Set<String>()
    return (selected ?? fields.map(\.id)).compactMap { id in
      guard seen.insert(id).inserted, let field = fields.first(where: { $0.id == id }) else {
        return nil
      }
      return Self(field: field, width: widths[id] ?? (field.type == "markdown" ? 360 : 180))
    }
  }

  func text(in row: WorkspaceRecord) -> String { field.formValue(row[id]) }
}

struct NativeGridRow: Identifiable {
  let row: WorkspaceRow
  var id: Data { row.byteExactID }

  static func selected(in rows: [WorkspaceRow], ids: Set<Data>) -> WorkspaceRow? {
    guard ids.count == 1, let id = ids.first else { return nil }
    return rows.first { $0.byteExactID == id }
  }
}
