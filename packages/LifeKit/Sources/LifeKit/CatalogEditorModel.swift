import Foundation
import Observation

@MainActor @Observable
final class CatalogEditorModel: Identifiable {
  enum Mode: String, CaseIterable {
    case property = "Properties"
    case rule = "Rules"
  }
  struct Option: Identifiable {
    let id = UUID()
    var value: String
    var description: String
    var rank: JSONValue?
  }
  let id = UUID()
  let workspace: WorkspaceModel
  let context: WorkspaceEditingContext
  var mode = Mode.property
  private(set) var original: WorkspaceRecord?
  var key = ""
  var fields: WorkspaceRecord = [:]
  var options: [Option] = []
  private(set) var saving = false
  private(set) var failure: String?
  private(set) var receipt: String?
  private var baseline = Data()
  static let types = [
    "text", "markdown", "number", "int", "bool", "date", "datetime", "date_or_datetime", "json",
    "select", "multi_select", "ref", "multi_ref", "url", "email", "phone",
  ]
  private static let propertyKeys = [
    "label", "sort", "type", "required", "default_value", "options", "options_sql", "min_items",
    "max_items", "pattern", "ref_table", "derived_by", "inputs", "immutable", "deprecated",
    "description", "source", "source_ref",
  ]
  private static let ruleKeys = ["scope", "col", "kind", "text", "sql", "cmd", "enforce"]
  var entries: [WorkspaceRecord] {
    let rows = mode == .property ? workspace.catalog?.properties : workspace.catalog?.rules
    return (rows ?? []).filter { row in
      row["tbl"]?.text == context.table
        && (mode == .rule
          || !["id", "created_at", "updated_at", "hub_at", "deleted_at"].contains(
            row["col"]?.text ?? ""))
    }
  }
  var dirty: Bool { snapshot != baseline }
  private var submitted: WorkspaceRecord {
    var result = fields
    if mode == .property, ["select", "multi_select"].contains(fields["type"]?.text ?? "") {
      result["options"] = .array(
        options.map { option in
          var row: WorkspaceRecord = ["v": .string(option.value), "d": .string(option.description)]
          if let rank = option.rank { row["sort"] = rank }
          return .object(row)
        })
    }
    return result
  }
  private var snapshot: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return
      (try? encoder.encode(["key": .string(key), "fields": .object(submitted)] as WorkspaceRecord))
      ?? Data()
  }
  init(workspace: WorkspaceModel, context: WorkspaceEditingContext) {
    self.workspace = workspace
    self.context = context
    select(entries.first, mode: .property)
  }
  func select(_ row: WorkspaceRecord?, mode next: Mode? = nil) {
    guard !saving else { return }
    if let next { mode = next }
    original = row
    key = row?[mode == .property ? "col" : "id"]?.text ?? ""
    let allowed = mode == .property ? Self.propertyKeys : Self.ruleKeys
    fields =
      row?.filter { allowed.contains($0.key) }
      ?? (mode == .property
        ? ["type": .string("text")]
        : ["kind": .string("doctrine"), "scope": .string("table"), "enforce": .number(0)])
    if case .array(let values) = fields["options"] {
      options = values.compactMap { value in
        guard case .object(let row) = value else { return nil }
        return Option(
          value: row["v"]?.text ?? "", description: row["d"]?.text ?? "", rank: row["sort"])
      }
    } else {
      options = []
    }
    failure = nil
    receipt = nil
    baseline = snapshot
  }
  func save() async {
    guard !saving else { return }
    let values = submitted
    let identity = key
    let kind = mode
    let revision = original?["updated_at"]?.text.nonempty
    let adding = original == nil
    saving = true
    failure = nil
    receipt = nil
    defer { saving = false }
    do {
      let result = try await workspace.editCatalog(context: context) { client in
        if kind == .property {
          return try await client.saveCatalogProperty(
            CoreSaveCatalogPropertyArgs(
              table: context.table, column: identity, expectedUpdatedAt: revision, fields: values,
              addColumn: adding))
        }
        return try await client.saveCatalogRule(
          CoreSaveCatalogRuleArgs(
            table: context.table, id: identity, expectedUpdatedAt: revision, fields: values))
      }
      original = result
      baseline = snapshot
      receipt = "Saved to the catalog and its change log."
    } catch { failure = error.localizedDescription }
  }
}
