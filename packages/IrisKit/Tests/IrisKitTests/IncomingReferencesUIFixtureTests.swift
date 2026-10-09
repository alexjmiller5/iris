import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct IncomingReferencesUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_INCOMING_SIMULATOR"] != nil))
    func prepareIncomingReferencesUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_INCOMING_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      let store = try #require(model.editingContext?.draftStore)
      let ids =
        ["incoming-target", "incoming-deleted", "\u{00e9}", "e\u{0301}"]
        + (0..<20).map { String(format: "a-incoming-%02d", $0) }
      let exactIDs = Set(ids.map { Data($0.utf8) })
      for saved in try store.all()
      where saved.table == "notes"
        && saved.recordID.map({ exactIDs.contains(Data($0.utf8)) }) == true
      {
        try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
      }
      await model.close()
      let runtime = try IrisCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      _ = try await workspace.status()
      runtime.context.setObject(
        environment["IRIS_TEST_INCOMING_READ_ONLY"] == "1",
        forKeyedSubscript: "incomingReadOnly" as NSString)
      // Only the explicitly selected private simulator's synthetic local database is changed.
      runtime.context.evaluateScript(
        #"""
        IrisSql.run("UPDATE catalog_tables SET kind='table' WHERE id='notes'");
        IrisSql.run("UPDATE catalog_properties SET ref_table='notes' WHERE id IN ('notes.topic','notes.related')");
        IrisSql.run("INSERT OR REPLACE INTO notes(id,title,body) VALUES ('incoming-target','Target notebook','# Target body')");
        for (let i = 0; i < 20; i++) {
          const suffix = String(i).padStart(2,'0');
          IrisSql.run("INSERT OR REPLACE INTO notes(id,title,body,topic) VALUES (?,?,?,?)",
            ['a-incoming-'+suffix,'Incoming '+suffix,'Full incoming body '+suffix,'incoming-target']);
        }
        IrisSql.run("INSERT OR REPLACE INTO notes(id,title,body,topic) VALUES (?,?,?,?),(?,?,?,?)",
          ['\u00e9','Incoming composed','Composed full body','incoming-target',
           'e\u0301','Incoming decomposed','Decomposed full body','incoming-target']);
        IrisSql.run("INSERT OR REPLACE INTO notes(id,title,topic,deleted_at) VALUES ('incoming-deleted','Incoming deleted','incoming-target','2026-01-01')");
        IrisSql.run("UPDATE notes SET related=? WHERE id='a-incoming-00'", [JSON.stringify(['incoming-target','incoming-target'])]);
        IrisSql.run("INSERT OR REPLACE INTO _core_state(key,value) VALUES ('skipped_tables',?)", [JSON.stringify(incomingReadOnly ? ['notes'] : [])]);
        if (incomingReadOnly) IrisSql.run("UPDATE catalog_tables SET kind='system' WHERE id='notes'");
        """#)
      try #require(runtime.context.exception == nil)
      let first = try await workspace.referencedBy(
        CoreReferencedByArgs(
          table: "notes", rowId: "incoming-target", sourceTable: "notes", column: "topic", limit: 20
        ))
      #expect(first.rows.count == 20 && first.nextOffset == 20)
      let second = try await workspace.referencedBy(
        CoreReferencedByArgs(
          table: "notes", rowId: "incoming-target", sourceTable: "notes", column: "topic",
          offset: 20))
      #expect(second.rows.count == 2 && second.nextOffset == nil)
      #expect(Set((first.rows + second.rows).map(\.byteExactID)).count == 22)
      #expect(!(first.rows + second.rows).contains { $0.label == "Incoming deleted" })
      try await workspace.close()
    }
  #endif
}
