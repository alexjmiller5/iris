import Foundation

/// Window-local selection never becomes catalog or workspace data.
struct NativeRowSelection {
  struct Scope: Equatable {
    let workspace: ObjectIdentifier
    let generation: Int
    let table: Data
  }
  private var scope: Scope?
  private var ids = Set<Data>()
  func selected(in current: Scope?, rows: [WorkspaceRow]) -> Set<Data> {
    guard let current, scope == current else { return [] }
    return ids.intersection(Set(rows.map(\.byteExactID)))
  }
  mutating func set(_ selected: Set<Data>, in current: Scope?, rows: [WorkspaceRow]) {
    scope = current
    ids = current == nil ? [] : selected.intersection(Set(rows.map(\.byteExactID)))
  }
  mutating func retain(in current: Scope?, rows: [WorkspaceRow]) {
    set(selected(in: current, rows: rows), in: current, rows: rows)
  }
}
