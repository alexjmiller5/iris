import Foundation

/// A draft owns the selected IDs. Search results never replace that selection.
struct ReferenceSelection {
  private(set) var ids: [String]
  let multiple: Bool
  private let initialIDs: [String]
  private let initialValue: String

  init(value: String, multiple: Bool) throws {
    self.multiple = multiple
    ids =
      multiple
      ? (value.isEmpty ? [] : try JSONDecoder().decode([String].self, from: Data(value.utf8)))
      : (value.isEmpty ? [] : [value])
    initialIDs = ids
    initialValue = value
  }

  var value: String {
    if ids.map({ Data($0.utf8) }) == initialIDs.map({ Data($0.utf8) }) { return initialValue }
    // String arrays always encode. An empty multi-reference is an explicit empty array.
    return multiple
      ? String(decoding: try! JSONEncoder().encode(ids), as: UTF8.self) : ids.first ?? ""
  }

  mutating func choose(_ id: String) {
    if !multiple { ids = [id] } else if contains(id) { remove(id) } else { ids.append(id) }
  }

  func contains(_ id: String) -> Bool { ids.contains { $0.utf8.elementsEqual(id.utf8) } }

  mutating func remove(_ id: String) { ids.removeAll { $0.utf8.elementsEqual(id.utf8) } }
}
