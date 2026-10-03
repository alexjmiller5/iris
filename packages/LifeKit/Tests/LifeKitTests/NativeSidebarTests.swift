import Testing

@testable import LifeKit

struct NativeSidebarTests {
  @Test func onlyCoreReadOnlyGroupsTablesAndKeepsCatalogOrderAndPurpose() {
    let tables = NativeSidebarTables([
      ["id": .string("notes"), "purpose": .string("Capture Markdown"), "readOnly": .bool(false)],
      ["id": .string("custom_service"), "purpose": .string("Service-owned records"), "readOnly": .bool(true)],
      ["id": .string("history_like_name"), "readOnly": .bool(false)],
      ["id": .string("unknown_flag")],
      ["id": .string("catalog_custom"), "readOnly": .bool(true)],
    ])
    #expect(tables.ordinary.map(\.id) == ["notes", "history_like_name", "unknown_flag"])
    #expect(tables.system.map(\.id) == ["custom_service", "catalog_custom"])
    #expect(tables.ordinary.first?.purpose == "Capture Markdown")
    #expect(tables.system.first?.purpose == "Service-owned records")
    #expect(tables.ordinary.last?.purpose == nil)
  }

  @Test func refreshedCoreMetadataMovesATableWithoutDroppingIt() {
    let before = NativeSidebarTables([["id": .string("notes"), "readOnly": .bool(false)]])
    let after = NativeSidebarTables([["id": .string("notes"), "readOnly": .bool(true)]])
    #expect(before.ordinary.map(\.id) == ["notes"] && before.system.isEmpty)
    #expect(after.ordinary.isEmpty && after.system.map(\.id) == ["notes"])
  }
}
