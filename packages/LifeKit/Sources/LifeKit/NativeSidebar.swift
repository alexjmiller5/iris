import Foundation

struct NativeSidebarTable: Identifiable {
  let id: String
  let purpose: String?
}

struct NativeSidebarTables {
  private(set) var ordinary: [NativeSidebarTable] = []
  private(set) var system: [NativeSidebarTable] = []

  init(_ tables: [WorkspaceRecord]) {
    for table in tables {
      guard let id = table["id"]?.text, !id.isEmpty else { continue }
      let item = NativeSidebarTable(id: id, purpose: table["purpose"]?.text.nonempty)
      if table["readOnly"] == .bool(true) { system.append(item) }
      else { ordinary.append(item) }
    }
  }
}
