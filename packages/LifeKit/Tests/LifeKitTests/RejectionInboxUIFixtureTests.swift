import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

/// App-hosted fixture only, never ordinary SwiftPM data setup. On the explicitly
/// selected private simulator, run phase=seed, the two RejectionInboxUITests,
/// then phase=verify. Reseed before repeating either UI flow.
@MainActor
struct RejectionInboxUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(.enabled(if:
      ProcessInfo.processInfo.environment["LIFE_UI_TEST_REJECTIONS_SIMULATOR"] != nil
      && ProcessInfo.processInfo.environment["LIFE_UI_TEST_REJECTIONS_PHASE"] == "seed"))
    func prepareRejectionInboxUIFixture() async throws {
      try requirePrivateSimulator()
      let model = WorkspaceModel()
      try model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      let store = try #require(model.editingContext?.draftStore)
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      _ = try await workspace.status()
      runtime.context.evaluateScript(
        #"""
        const marker = 'Synthetic Issues UI fixture';
        const existing = LifeSql.all("SELECT name FROM main.sqlite_master WHERE name='ui_rejections'");
        const owner = LifeSql.all("SELECT purpose FROM catalog_tables WHERE id='ui_rejections'");
        if ((existing.length || owner.length) && owner[0]?.purpose !== marker)
          throw new Error('Refusing to adopt a table not owned by the Issues fixture');
        const ddl = `CREATE TABLE IF NOT EXISTS ui_rejections (
          id TEXT PRIMARY KEY NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          deleted_at TEXT, hub_at TEXT, title TEXT, body TEXT, locked TEXT, retired TEXT)`;
        LifeSql.run(ddl);
        if (!LifeSql.all('SELECT 1 FROM _schema_log WHERE ddl=?', [ddl]).length)
          LifeSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
        LifeSql.run("INSERT OR REPLACE INTO catalog_tables(id,kind,display,purpose) VALUES ('ui_rejections','table','title',?)", [marker]);
        const fields = [
          ['title','Title','text',0,0], ['body','Body','markdown',0,0],
          ['locked','Locked','text',1,0], ['retired','Retired','text',0,1],
          ['id','ID','text',0,0], ['updated_at','Revision','datetime',0,0]
        ];
        fields.forEach(([col,label,type,immutable,deprecated],sort) => LifeSql.run(
          'INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,immutable,deprecated,sort) VALUES (?,?,?,?,?,?,?,?)',
          ['ui_rejections.'+col,'ui_rejections',col,label,type,immutable,deprecated,sort]));
        for (const suffix of ['save','stale']) {
          const id = 'issues-'+suffix;
          LifeSql.run('DELETE FROM _core_rejected WHERE tbl=? AND row_id=?', ['ui_rejections',id]);
          LifeSql.run('DELETE FROM _core_pending WHERE tbl=? AND row_id=?', ['ui_rejections',id]);
          LifeSql.run(`INSERT OR REPLACE INTO ui_rejections(id,created_at,updated_at,title,body,locked,retired)
            VALUES (?, '2001-01-01T00:00:00.000Z', '2001-01-01T00:00:00.000Z', ?, ?, 'Locked current','Retired current')`,
            [id,'Issues '+suffix+' before','Before '+suffix+' body']);
        }
        """#)
      try #require(runtime.context.exception == nil)
      for saved in try store.all()
      where saved.table == "ui_rejections"
        && ["issues-save", "issues-stale"].contains(saved.recordID ?? "")
      {
        try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
      }
      for suffix in ["save", "stale"] {
        let id = "issues-" + suffix
        let before = try #require(try await workspace.rows(table: "ui_rejections").first { $0.id == id })
        let submitted = before.record.merging([
          "title": .string("Issues \(suffix) submitted"),
          "body": .string("Rejected \(suffix) body"),
          "locked": .string("Locked rejected"),
          "retired": .string("Retired rejected"),
          "removed": .string("Removed submitted value"),
        ]) { _, next in next }
        let current = try await workspace.write(table: "ui_rejections", patch: [
          "id": .string(id), "title": .string("Issues \(suffix) current"),
          "body": .string("Current \(suffix) body")
        ], expectedUpdatedAt: before.record["updated_at"]?.text)
        try #require(current["updated_at"] != submitted["updated_at"])
        let entry = CoreRejectedEdit(table: "ui_rejections", rowID: id, submitted: submitted,
          errors: [["id": .string(id), "message": .string("Synthetic rejected edit")]])
        runtime.context.setObject(
          String(decoding: try JSONEncoder().encode(entry), as: UTF8.self),
          forKeyedSubscript: "rejectionFixtureEntry" as NSString)
        runtime.context.evaluateScript(
          #"""
          {
            const entry = JSON.parse(rejectionFixtureEntry);
            LifeSql.run('INSERT INTO _core_rejected(tbl,row_id,row,errors) VALUES (?,?,?,?)',
              [entry.table,entry.rowID,JSON.stringify(entry.submitted),JSON.stringify(entry.errors)]);
          }
          """#)
        try #require(runtime.context.exception == nil)
      }
      try await workspace.close()

      // Make the stale review using the same host preparation and real core as
      // the UI, then advance that record normally. No timers or product hooks.
      await model.open()
      let client = try #require(model.client)
      model.table = "ui_rejections"
      let page = try await client.rejections(CoreRejectionsArgs(limit: 200))
      let stale = try #require(page.rejections.first { $0.table == "ui_rejections" && $0.rowID == "issues-stale" })
      let prepared = try await model.prepareRejectionReview(stale, workspace: client,
        generation: model.workspaceGeneration)
      try #require(prepared.editor.autosavePaused)
      try #require(prepared.editor.draft.fields.map(\.id) == ["title", "body"])
      let newer = try await client.write(table: "ui_rejections", patch: [
        "id": .string("issues-stale"), "title": .string("Issues stale newer"),
        "body": .string("Newer saved body")
      ], expectedUpdatedAt: prepared.editor.draft.original?["updated_at"]?.text)
      try #require(newer["updated_at"] != prepared.editor.draft.original?["updated_at"])
      let journal = try #require(try store.load(table: "ui_rejections", recordID: "issues-stale"))
      #expect(journal.autosavePaused == true && journal.draft.values["body"] == "Rejected stale body")
      #expect(try store.load(table: "ui_rejections", recordID: "issues-save") == nil)
      await model.close()
    }

    @Test(.enabled(if:
      ProcessInfo.processInfo.environment["LIFE_UI_TEST_REJECTIONS_SIMULATOR"] != nil
      && ProcessInfo.processInfo.environment["LIFE_UI_TEST_REJECTIONS_PHASE"] == "verify"))
    func verifyRejectionInboxUIResults() async throws {
      try requirePrivateSimulator()
      let path = try WorkspaceModel.localURL()
      let workspace = try NativeWorkspace(path: path.path)
      let rows = try await workspace.rows(table: "ui_rejections")
      let saved = try #require(rows.first { $0.id == "issues-save" }?.record)
      let stale = try #require(rows.first { $0.id == "issues-stale" }?.record)
      #expect(saved["title"] == .string("Issues save submitted"))
      #expect(saved["body"] == .string("Rejected save body"))
      #expect(stale["title"] == .string("Issues stale newer"))
      #expect(stale["body"] == .string("Newer saved body"))
      for row in [saved, stale] {
        #expect(row["locked"] == .string("Locked current"))
        #expect(row["retired"] == .string("Retired current"))
        #expect(row["created_at"] == .string("2001-01-01T00:00:00.000Z"))
        #expect(row["removed"] == nil && row["deleted_at"] == .null)
      }
      let page = try await workspace.rejections(CoreRejectionsArgs(limit: 200))
      let rejections = page.rejections.filter { $0.table == "ui_rejections" }
      #expect(Set(rejections.map(\.rowID)) == ["issues-save", "issues-stale"])
      #expect(rejections.allSatisfy { $0.submitted["removed"] == .string("Removed submitted value") })
      let store = EditorDraftStore(root: path.deletingLastPathComponent().appendingPathComponent("drafts"), workspace: path)
      #expect(try store.load(table: "ui_rejections", recordID: "issues-save") == nil)
      let journal = try #require(try store.load(table: "ui_rejections", recordID: "issues-stale"))
      #expect(journal.autosavePaused == true && journal.failure != nil)
      #expect(journal.draft.values["title"] == "Issues stale submitted")
      #expect(journal.draft.values["body"] == "Rejected stale body")
      #expect(journal.draft.original?["updated_at"] != stale["updated_at"])
      try await workspace.close()
    }

    private func requirePrivateSimulator() throws {
      let environment = ProcessInfo.processInfo.environment
      let requested = try #require(environment["LIFE_UI_TEST_REJECTIONS_SIMULATOR"])
      let actual = try #require(environment["SIMULATOR_UDID"])
      try #require(!requested.isEmpty && requested == actual)
    }
  #endif
}
