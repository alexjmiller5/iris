import Foundation

struct NativeChoiceOption: Identifiable {
  let value: String
  let description: String?
  var id: Data { Data(value.utf8) }
}

struct NativeChoiceOptions {
  let choices: [NativeChoiceOption]
  let selection: ReferenceSelection

  init(field: CatalogField, dynamic: [String], value: String) throws {
    selection = try ReferenceSelection(value: value, multiple: field.type == "multi_select")
    var definitions: [Data: NativeChoiceOption] = [:]
    if case .array(let entries) = field.property["options"] {
      for case .object(let entry) in entries {
        guard let value = entry["v"]?.text else { continue }
        let id = Data(value.utf8)
        if definitions[id] == nil {
          definitions[id] = NativeChoiceOption(value: value, description: entry["d"]?.text.nonempty)
        }
      }
    }
    var seen = Set<Data>()
    choices = (field.options + dynamic + selection.ids).compactMap { value in
      let id = Data(value.utf8)
      guard seen.insert(id).inserted else { return nil }
      return definitions[id] ?? NativeChoiceOption(value: value, description: nil)
    }
  }
}
