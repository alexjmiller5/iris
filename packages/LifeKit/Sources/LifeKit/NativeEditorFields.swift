import Foundation

struct NativeEditorFields {
  let primary: [CatalogField]
  let empty: [CatalogField]
  let additional: [CatalogField]

  init(
    fields: [CatalogField], visibleColumns: [String]?, titleColumn: String?, isNew: Bool,
    invalidColumns: [String], emptyColumns: Set<Data> = []
  ) {
    let selected = visibleColumns.map { Set($0.map { Data($0.utf8) }) }
    let invalid = Set(invalidColumns.map { Data($0.utf8) })
    let title = titleColumn.map { Data($0.utf8) }
    func pinned(_ field: CatalogField) -> Bool {
      let id = Data(field.id.utf8)
      return id == title || (isNew && field.required) || invalid.contains(id)
    }
    func visible(_ field: CatalogField) -> Bool {
      pinned(field) || selected == nil || selected?.contains(Data(field.id.utf8)) == true
    }
    func collapsed(_ field: CatalogField) -> Bool {
      !isNew && !pinned(field) && emptyColumns.contains(Data(field.id.utf8))
    }
    primary = fields.filter { visible($0) && !collapsed($0) }
    empty = fields.filter { visible($0) && collapsed($0) }
    additional = fields.filter { !visible($0) }
  }

  static func emptyColumns(fields: [CatalogField], values: [String: String]) -> Set<Data> {
    Set(
      fields.filter { field in
        let value = values[field.id] ?? ""
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard ["multi_select", "multi_ref"].contains(field.type),
          let choices = try? JSONDecoder().decode([String].self, from: Data(value.utf8))
        else { return false }
        return choices.isEmpty
      }.map { Data($0.id.utf8) })
  }
}
