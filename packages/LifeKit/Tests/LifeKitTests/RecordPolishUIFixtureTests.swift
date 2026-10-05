import Foundation
import Testing

@testable import LifeKit

@MainActor
struct RecordPolishUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] != nil))
    func prepareRecordPolishFixture() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try model.forgetConnection()
      await model.open()
      if let store = model.editingContext?.draftStore {
        for saved in try store.all() where saved.table == "notes" {
          try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
        }
      }
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      runtime.context.evaluateScript(
        #"""
        LifeSql.run("INSERT OR REPLACE INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
          ['fixture-record-polish','notes','guideline',0,null,
          'Keep a useful record title. '+('Synthetic catalog guidance should remain available without hiding editable fields. ').repeat(18)]);
        LifeSql.run("CREATE TABLE IF NOT EXISTS readonly_notes (id TEXT PRIMARY KEY, title TEXT, detail TEXT, topic_id TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)");
        LifeSql.run("INSERT OR REPLACE INTO catalog_tables(id,kind,display,purpose) VALUES ('readonly_notes','system','title','Synthetic read-only presentation')");
        for (const [col,type,sort] of [['title','text',0],['detail','text',1],['topic_id','ref',2]])
          LifeSql.run("INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,sort,ref_table) VALUES (?,?,?,?,?,?,?)",
            ['readonly_notes.'+col,'readonly_notes',col,col,type,sort,col==='topic_id'?'topics':null]);
        LifeSql.run("INSERT OR REPLACE INTO topics(id,title) VALUES ('fixture-readonly-topic','Linked fixture topic')");
        LifeSql.run("INSERT OR REPLACE INTO readonly_notes(id,title,detail,topic_id) VALUES ('opaque-fixture-record','Read-only title','Visible read-only detail','fixture-readonly-topic')");
        """#)
      try #require(runtime.context.exception == nil)
      try await workspace.close()
    }
  #endif
}
