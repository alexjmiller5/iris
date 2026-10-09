import Foundation

struct NativeSidebarTable: Identifiable {
  let id: String
  let purpose: String?
}

struct NativeSidebarTables {
  private(set) var ordinary: [NativeSidebarTable] = []
  private(set) var system: [NativeSidebarTable] = []

  init(_ tables: [WorkspaceRecord], pins: [CoreSidebarPin] = []) {
    let pinned = Set(pins.filter { $0.deletedAt == nil }.map(\.tbl))
    for table in tables {
      guard let id = table["id"]?.text, !id.isEmpty, !pinned.contains(id) else { continue }
      let item = NativeSidebarTable(id: id, purpose: table["purpose"]?.text.nonempty)
      if table["readOnly"] == .bool(true) { system.append(item) }
      else { ordinary.append(item) }
    }
  }
}
