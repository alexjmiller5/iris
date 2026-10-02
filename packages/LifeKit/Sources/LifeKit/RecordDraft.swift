import Foundation

struct CatalogField: Identifiable {
  let property: WorkspaceRecord
  var id: String { property["col"]?.text ?? "" }
  var label: String { property["label"]?.text.nonempty ?? id }
  var type: String { property["type"]?.text.nonempty ?? "text" }
  var required: Bool { property["required"]?.isTrue == true }
  var description: String { property["description"]?.text ?? "" }
  var options: [String] {
    guard case .array(let options) = property["options"] else { return [] }
    return options.compactMap {
      if case .object(let option) = $0 { return option["v"]?.text }
      return nil
    }
  }
  var help: String {
    var parts = [description]
    if required { parts.append("Required.") }
    if let pattern = property["pattern"]?.text.nonempty { parts.append("Pattern: \(pattern)") }
    if let reference = property["ref_table"]?.text.nonempty {
      parts.append("Choose from \(reference).")
    }
    if ["json", "multi_select"].contains(type) { parts.append("Enter JSON source.") }
    if type == "date" { parts.append("YYYY-MM-DD") }
    if type == "datetime" { parts.append("UTC timestamp with milliseconds.") }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
  }
}
extension String {
  var nonempty: String? { isEmpty ? nil : self }
}

struct RecordDraft {
  var values: [String: String]
  let fields: [CatalogField]
  private let initial: [String: String]
  private let original: WorkspaceRecord?
  init(properties: [WorkspaceRecord], original: WorkspaceRecord?) {
    self.original = original
    fields = properties.map(CatalogField.init).filter { field in
      !["id", "created_at", "updated_at", "deleted_at", "hub_at"].contains(field.id)
        && field.property["derived_by"]?.text.nonempty == nil
        && field.property["deprecated"]?.isTrue != true
        && (original == nil || field.property["immutable"]?.isTrue != true)
    }
    initial = Dictionary(
      uniqueKeysWithValues: fields.map { field in
        let value = original?[field.id]?.text ?? ""
        return (
          field.id,
          field.type == "bool"
            ? (original?[field.id]?.isTrue == true
              ? "true"
              : original?[field.id] == .number(0) || original?[field.id] == .bool(false)
                ? "false" : value) : value
        )
      })
    values = initial
  }
  var patch: WorkspaceRecord {
    var patch: WorkspaceRecord = [:]
    if let id = original?["id"] { patch["id"] = id }
    for field in fields {
      let value = values[field.id] ?? ""
      guard value != initial[field.id] else { continue }
      if value.isEmpty {
        patch[field.id] = .null
      } else if field.type == "bool", ["true", "false"].contains(value) {
        patch[field.id] = .bool(value == "true")
      } else {
        patch[field.id] = .string(value)
      }
    }
    return patch
  }
}
