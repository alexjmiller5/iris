import Foundation

struct NativeEditorFields {
  let primary: [CatalogField]
  let additional: [CatalogField]

  init(
    fields: [CatalogField], visibleColumns: [String]?, titleColumn: String?, isNew: Bool,
    invalidColumns: [String]
  ) {
    let selected = visibleColumns.map { Set($0.map { Data($0.utf8) }) }
    let invalid = Set(invalidColumns.map { Data($0.utf8) })
    let title = titleColumn.map { Data($0.utf8) }
    func visible(_ field: CatalogField) -> Bool {
      let id = Data(field.id.utf8)
      return selected == nil || selected?.contains(id) == true || id == title
        || (isNew && field.required) || invalid.contains(id)
    }
    primary = fields.filter(visible)
    additional = fields.filter { !visible($0) }
  }
}
