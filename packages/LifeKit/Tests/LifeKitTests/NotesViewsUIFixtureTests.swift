import Foundation
import Testing

@testable import LifeKit

/// Seeds one private simulator's sample workspace for `NotesViewsUITests`: lifecycle
/// statuses with catalog descriptions, a flag naming its reason column, a preferred
/// default view, a separate related-record view and a Retired record. Synthetic only.
@MainActor
struct NotesViewsUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_NOTES_VIEWS_SIMULATOR"] != nil)
    )
    func prepareNotesViewsUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["LIFE_UI_TEST_NOTES_VIEWS_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      _ = try await workspace.status()
      runtime.context.evaluateScript(
        #"""
        const cols = LifeSql.all("PRAGMA table_info(notes)").map(r => r.name);
        if (!cols.includes('needs_review'))
          LifeSql.run("ALTER TABLE notes ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 0");
        if (!cols.includes('review_reason')) LifeSql.run("ALTER TABLE notes ADD COLUMN review_reason TEXT");
        LifeSql.run(`INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,default_value,description,sort)
          VALUES ('notes.needs_review','notes','needs_review','Needs review','bool','0','Cleanup flag; the reason is in review_reason.',5),
                 ('notes.review_reason','notes','review_reason','Review reason','text',NULL,'Why the record needs review.',6)`);
        LifeSql.run("UPDATE catalog_properties SET options=?, default_value=NULL WHERE id='notes.status'", [JSON.stringify([
          {v:'Working',d:'Actively being developed.'},{v:'Reference',d:'Kept to consult or reuse.'},
          {v:'Someday',d:'Deferred; not a commitment.'},{v:'History',d:'A record of something finished.'},
          {v:'Retired',d:'Superseded and no longer in use.'}])]);
        LifeSql.run("INSERT OR REPLACE INTO topics(id,title) VALUES ('nv-trip','Synthetic trip')");
        for (const [id, title, status, topic, flag, reason] of [
          ['nv-working','Working draft','Working','nv-trip',0,null],
          ['nv-reference','Reference sheet','Reference',null,1,'Duplicates the packing list'],
          ['nv-someday','Someday idea','Someday',null,0,null],
          ['nv-history','History log','History','nv-trip',0,null],
          ['nv-retired','Retired lantern plan','Retired','nv-trip',0,null]])
          LifeSql.run("INSERT OR REPLACE INTO notes(id,title,status,topic,needs_review,review_reason) VALUES (?,?,?,?,?,?)",
            [id, title, status, topic, flag, reason]);
        const eq = (column, value) => ({column, op: 'eq', value});
        for (const [id, name, definition] of [
          ['nv-everyday','Everyday',{version:2,columns:['title','status'],
            groups:[{match:'any',filters:[eq('status','Working'),eq('status','Reference')]}]}],
          ['nv-someday-view','Someday',{version:1,columns:['title','status'],filters:[eq('status','Someday')]}],
          ['nv-linked','Linked',{version:1,columns:['title','status'],filters:[{column:'status',op:'ne',value:'Retired'}]}]])
          LifeSql.run("INSERT OR REPLACE INTO views(id,name,tbl,definition) VALUES (?,?,'notes',?)",
            [id, name, JSON.stringify(definition)]);
        LifeSql.run("INSERT OR REPLACE INTO view_defaults(id,tbl,view_id) VALUES ('default:v1:6e6f746573','notes','nv-everyday')");
        LifeSql.run("INSERT OR REPLACE INTO related_view_defaults(id,tbl,view_id) VALUES ('related:v1:6e6f746573','notes','nv-linked')");
        """#)
      try #require(runtime.context.exception == nil)
      let preferred = try await workspace.getViewDefault(table: "notes")
      try #require(preferred.view?.name == "Everyday")
      _ = try await workspace.close()
    }
  #endif
}
