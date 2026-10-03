import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct OpaqueRecordIdentityTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_OPAQUE_ID_SIMULATOR"] != nil))
    func prepareOpaqueIDRecoveryUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_OPAQUE_ID_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      try #require(model.client != nil)
      let store = try #require(model.editingContext?.draftStore)
      for saved in try store.all()
      where saved.table == "notes"
        && [Data([0xc3, 0xa9]), Data([0x65, 0xcc, 0x81])].contains(
          saved.recordID.map { Data($0.utf8) } ?? Data())
      {
        try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
      }
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      // External/imported opaque IDs are legal. Core creation intentionally generates IDs.
      runtime.context.evaluateScript(
        #"""
        LifeSql.run("INSERT OR REPLACE INTO notes (id,title) VALUES (?,?),(?,?)",
          ['\u00e9','Opaque first record','e\u0301','Opaque second record']);
        """#)
      try #require(runtime.context.exception == nil)
      let rows = try await workspace.rows(table: "notes")
      #expect(rows.contains { Data($0.id.utf8) == Data([0xc3, 0xa9]) })
      #expect(rows.contains { Data($0.id.utf8) == Data([0x65, 0xcc, 0x81]) })
      try await workspace.close()
    }
  #endif
}
