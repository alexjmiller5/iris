import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct TypedFieldsUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_FIELDS_SIMULATOR"] != nil))
    func prepareTypedFieldsUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_FIELDS_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try model.forgetConnection()
      await model.open()
      let store = try #require(model.editingContext?.draftStore)
      for saved in try store.all() where saved.table == "field_examples" {
        try store.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
      }
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      // This opt-in fixture only changes the explicitly selected private simulator.
      runtime.context.evaluateScript(
        #"""
        const ddl = `CREATE TABLE IF NOT EXISTS field_examples (
          id TEXT PRIMARY KEY NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
          deleted_at TEXT, hub_at TEXT, title TEXT, tags TEXT, dynamic TEXT,
          spelling TEXT, day TEXT, moment TEXT, flag INTEGER, website TEXT, email TEXT, phone TEXT, logo TEXT, locked TEXT)`;
        LifeSql.run(ddl);
        if (!LifeSql.all('SELECT 1 FROM _schema_log WHERE ddl=?', [ddl]).length)
          LifeSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
        LifeSql.run("INSERT OR REPLACE INTO catalog_tables(id,kind,display,purpose) VALUES ('field_examples','table','title','Synthetic typed-field verification')");
        if (!LifeSql.all('PRAGMA table_info(field_examples)').some(c => c.name === 'logo'))
          LifeSql.run('ALTER TABLE field_examples ADD COLUMN logo TEXT');
        if (!LifeSql.all('PRAGMA table_info(field_examples)').some(c => c.name === 'locked'))
          LifeSql.run('ALTER TABLE field_examples ADD COLUMN locked TEXT');
        const fields = [
          ['title','Title','text',null,null],
          ['tags','Tags','multi_select',JSON.stringify([{v:'Alpha'},{v:'Beta'}]),null],
          ['dynamic','Dynamic choice','select',null,"SELECT 'Dynamic one' AS v UNION SELECT 'Dynamic two' AS v"],
          ['spelling','Spelling','select',JSON.stringify([{v:'\u00e9',d:'First spelling'},{v:'e\u0301',d:'Second spelling'}]),null],
          ['day','Day','date',null,null],['moment','Moment','datetime',null,null],
          ['flag','Flag','bool',null,null],['website','Website','url',null,null],
          ['email','Email','email',null,null],['phone','Phone','phone',null,null],
          ['logo','Logo','text',null,null],['locked','Locked','text',null,null]
        ];
        fields.forEach(([col,label,type,options,sql],sort) => LifeSql.run(
          'INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,options,options_sql,sort) VALUES (?,?,?,?,?,?,?,?)',
          ['field_examples.'+col,'field_examples',col,label,type,options,sql,sort]));
        LifeSql.run("DELETE FROM field_examples");
        for (const [id,title,tags] of [
          ['typed-choices','Choice field notebook','[ "Unknown", "Alpha" ]'],
          ['typed-dates','Date field notebook','["Alpha"]']
        ]) LifeSql.run(`INSERT INTO field_examples(id,title,tags,dynamic,spelling,day,moment,flag,website,email,phone)
          VALUES (?,?,?,?,?,?,?,0,'https://example.test','note@example.test','+00 (000) 000-0000')`,
          [id,title,tags,'Dynamic one','\u00e9','2024-02-29','2024-02-29T23:04:05.123Z']);
        LifeSql.run("UPDATE catalog_properties SET immutable=1 WHERE id='field_examples.locked'");
        LifeSql.run("UPDATE field_examples SET locked='Read-only fixture value'");
        LifeSql.run('UPDATE field_examples SET logo=?', ['data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#2060d0"/><circle cx="50" cy="50" r="30" fill="#f0c020"/></svg>')]);
        """#)
      try #require(runtime.context.exception == nil)
      #expect(
        try await workspace.options(table: "field_examples", column: "dynamic") == [
          "Dynamic one", "Dynamic two",
        ])
      let row = try #require(
        try await workspace.rows(table: "field_examples").first { $0.id == "typed-choices" })
      #expect(row.record["tags"]?.text == "[ \"Unknown\", \"Alpha\" ]")
      try await workspace.close()
    }
  #endif
}
