import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct NavigationUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_NAVIGATION_SIMULATOR"] != nil))
    func prepareNavigationUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["LIFE_UI_TEST_NAVIGATION_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      let store = try #require(model.editingContext?.draftStore)
      for saved in try store.all() where saved.recordID?.hasPrefix("nav-") == true {
        try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
      }
      await model.close()
      let path = try WorkspaceModel.localURL()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: path.path, runtime: runtime)
      _ = try await workspace.status()
      // This fixture is restricted to the explicitly selected disposable simulator.
      runtime.context.evaluateScript(
        #"""
        LifeSql.run("UPDATE catalog_tables SET kind='table',purpose='Synthetic notes for navigation' WHERE id='notes'");
        LifeSql.run("UPDATE catalog_properties SET ref_table='topics' WHERE id='notes.topic'");
        LifeSql.run("INSERT OR REPLACE INTO topics(id,title) VALUES ('nav-topic','Navflora topic')");
        for (let i = 0; i < 52; i++) {
          const suffix = String(i).padStart(2,'0');
          LifeSql.run("INSERT OR REPLACE INTO notes(id,title,body,topic) VALUES (?,?,?,?)",
            ['nav-note-'+suffix,'Navflora note '+suffix,'Full navigation body '+suffix,'nav-topic']);
        }
        LifeSql.run("INSERT OR REPLACE INTO notes(id,title,body,deleted_at) VALUES ('nav-trash','Navigation discarded','Retained full trash body','2026-01-01')");
        LifeSql.run("INSERT OR REPLACE INTO views(id,name,tbl,definition) VALUES ('nav-view','Navigation focus','notes',?)", [JSON.stringify({version:1,search:'navflora note 00'})]);
        LifeSql.run("INSERT OR REPLACE INTO views(id,name,tbl,definition) VALUES ('nav-broken','Navigation unavailable','notes','{\"version\":999}')");
        LifeSql.run("INSERT OR REPLACE INTO _core_state(key,value) VALUES ('skipped_tables','[]')");
        """#)
      try #require(runtime.context.exception == nil)
      let views = try await workspace.listViews(table: "notes")
      #expect(views.views.first { $0.id == "nav-view" }?.unavailable == nil)
      #expect(views.views.first { $0.id == "nav-broken" }?.unavailable != nil)
      #expect(try await workspace.search(CoreSearchArgs(text: "navflora", limit: 100)).count > 50)
      try await workspace.close()
      let recents = NativeRecentsStore(root: path.deletingLastPathComponent(), workspace: path)
      _ = try recents.load()
      _ = try recents.update { _ in
        [
          NativeDestination(table: "notes", rowID: "nav-missing"),
          NativeDestination(table: "notes", rowID: "nav-trash"),
        ]
      }
    }
  #endif
}
