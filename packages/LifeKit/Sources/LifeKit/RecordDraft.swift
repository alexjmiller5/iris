import Foundation

struct CatalogField: Identifiable, Codable {
  let property: WorkspaceRecord
  var id: String { property["col"]?.text ?? "" }
  var label: String { property["label"]?.text.nonempty ?? id }
  var type: String { property["type"]?.text.nonempty ?? "text" }
  var required: Bool { property["required"]?.isTrue == true }
  var description: String { property["description"]?.text ?? "" }
  func formValue(_ value: JSONValue?) -> String {
    if type == "bool" {
      if value?.isTrue == true { return "true" }
      if value == .number(0) || value == .bool(false) { return "false" }
    }
    return value?.text ?? ""
  }
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

struct RecordDraft: Codable {
  var values: [String: String]
  let fields: [CatalogField]
  private var initial: [String: String]
  private(set) var original: WorkspaceRecord?
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
        (field.id, field.formValue(original?[field.id]))
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

  var unknownValues: [String: String] {
    values.filter { key, value in !fields.contains(where: { $0.id == key }) && !value.isEmpty }
  }

  mutating func reconcileUndo(_ receipt: WorkspaceRecord) {
    for field in fields {
      let value = field.formValue(receipt[field.id])
      if values[field.id] == initial[field.id] { values[field.id] = value }
      initial[field.id] = value
    }
    original = receipt
  }

  mutating func acknowledge(_ receipt: WorkspaceRecord, sent: WorkspaceRecord) {
    // Retain the exact fields loaded when this editor opened. A catalog refresh
    // must not add empty fields to an existing draft or its next patch.
    for field in fields where sent[field.id] != nil {
      let submitted = sent[field.id] == .null ? "" : sent[field.id]?.text ?? ""
      let acknowledged = field.formValue(receipt[field.id])
      if values[field.id] == submitted { values[field.id] = acknowledged }
      initial[field.id] = acknowledged
    }
    original = receipt
  }
}
