import Foundation
import JavaScriptCore
import SQLite3
import Testing

@testable import LifeKit

@MainActor
struct SQLiteBridgeTests {

  @Test(arguments: ["no-log", "custom-body", "source-exists", "source-view-exists"])
  func recoveryDoesNotRewriteUnprovenOrCustomTriggers(reason: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("replica.sqlite").path
    var sql = """
      PRAGMA legacy_alter_table=ON;
      CREATE TABLE links (id TEXT PRIMARY KEY, updated_at TEXT);
      CREATE TRIGGER links_updated_at AFTER UPDATE ON links FOR EACH ROW
      WHEN NEW.updated_at = OLD.updated_at BEGIN
        UPDATE links SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid;
      END;
      CREATE TABLE _schema_log (ddl TEXT);
      ALTER TABLE links RENAME TO records;
      """
    if reason != "no-log" {
      sql += "; INSERT INTO _schema_log VALUES ('ALTER TABLE links RENAME TO records');"
    }
    if reason == "source-exists" {
      sql += "; CREATE TABLE links (id TEXT, updated_at TEXT);"
    }
    if reason == "source-view-exists" {
      sql += "; CREATE VIEW links AS SELECT * FROM records;"
    }
    if reason == "custom-body" {
      sql += """
        DROP TRIGGER links_updated_at;
        CREATE TRIGGER links_updated_at AFTER UPDATE ON "records" FOR EACH ROW
        WHEN NEW.updated_at = OLD.updated_at BEGIN
          UPDATE links SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid;
          DELETE FROM records;
        END;
        """
    }
    let before = try seedLegacyFixture(path: path, sql: sql)
    let context = try #require(JSContext())
    let bridge = try SQLiteBridge(path: path)
    try bridge.install(in: context)
    #expect(
      context.evaluateScript(
        "LifeSql.all(\"SELECT sql FROM sqlite_master WHERE type='trigger'\")[0].sql")?.toString()
        == before)
    #expect(context.exception == nil)
  }

  @Test func reopeningLegacyRenameRepairsOnlyLoggedCanonicalTimestampTriggers() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("replica.sqlite").path
    let sql = """
      PRAGMA legacy_alter_table=ON;
      CREATE TABLE links (id TEXT PRIMARY KEY, updated_at TEXT, title TEXT);
      CREATE TRIGGER links_updated_at AFTER UPDATE ON links FOR EACH ROW
      WHEN NEW.updated_at = OLD.updated_at BEGIN
        UPDATE links SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid;
      END;
      CREATE TABLE _schema_log (ddl TEXT);
      INSERT INTO _schema_log VALUES ('ALTER TABLE links RENAME TO records');
      INSERT INTO links VALUES ('one','2020-01-01T00:00:00.000Z','Retained draft');
      ALTER TABLE links RENAME TO records;
      CREATE TABLE _core_pending (row_id TEXT);
      INSERT INTO _core_pending VALUES ('one');
      """
    _ = try seedLegacyFixture(path: path, sql: sql)
    let context = try #require(JSContext())
    let bridge = try SQLiteBridge(path: path)
    try bridge.install(in: context)
    let result = context.evaluateScript(
      #"""
      LifeSql.run('CREATE TABLE items (old_name TEXT)');
      LifeSql.run('ALTER TABLE items RENAME COLUMN old_name TO new_name');
      LifeSql.run("UPDATE records SET title='Edited' WHERE id='one'");
      JSON.stringify([LifeSql.all('SELECT title,updated_at FROM records')[0],
        LifeSql.all('SELECT row_id FROM _core_pending')[0].row_id,
        LifeSql.all('SELECT count(*) AS n FROM _schema_log')[0].n]);
      """#)
    #expect(context.exception == nil)
    let text = try #require(result?.toString())
    #expect(text.contains("Edited"))
    #expect(!text.contains("2020-01-01"))
    #expect(text.contains("one"))
    #expect(text.hasSuffix(",1]"))
  }

  private func seedLegacyFixture(path: String, sql: String) throws -> String {
    var database: OpaquePointer?
    try #require(sqlite3_open(path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    try #require(
      sqlite3_prepare_v2(
        database, "SELECT sql FROM sqlite_master WHERE type='trigger'", -1, &statement, nil)
        == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    try #require(sqlite3_step(statement) == SQLITE_ROW)
    return String(cString: try #require(sqlite3_column_text(statement, 0)))
  }

  @Test func renameColumnPreservesStoredValues() throws {
    let context = try #require(JSContext())
    let bridge = try SQLiteBridge(path: ":memory:")
    try bridge.install(in: context)
    let result = context.evaluateScript(
      #"""
      LifeSql.run('CREATE TABLE links (id TEXT PRIMARY KEY, updated_at TEXT)');
      LifeSql.run("CREATE TRIGGER links_updated_at AFTER UPDATE ON links FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE links SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid; END");
      LifeSql.run('ALTER TABLE links RENAME TO records');
      LifeSql.run('CREATE TABLE items (id TEXT PRIMARY KEY, old_name TEXT)');
      LifeSql.run("INSERT INTO items VALUES ('one','Original')");
      LifeSql.run('ALTER TABLE items RENAME COLUMN old_name TO new_name');
      LifeSql.all('SELECT new_name FROM items')[0].new_name;
      """#)
    #expect(context.exception == nil)
    #expect(result?.toString() == "Original")
  }

  @Test func quotedDelimitersRemainDataAndCTECannotWrite() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE "semi;quote""name" (id TEXT)');
      LifeSql.run('INSERT INTO "semi;quote""name" VALUES (?)', ['kept']);
      const metadata = LifeSql.all('PRAGMA main.table_info("semi;quote""name")');
      const value = LifeSql.all("/* comment */ SELECT '; /* --' AS value; -- trailing\\rcomment")[0].value;
      let rejected = false;
      try { LifeSql.all('WITH x AS (SELECT 1) DELETE FROM "semi;quote""name" RETURNING id'); }
      catch { rejected = true; }
      JSON.stringify([metadata[0].name, value, rejected, LifeSql.all('SELECT id FROM "semi;quote""name"')[0].id]);
      """)
    #expect(context.exception == nil)
    #expect(result?.toString() == #"["id","; /* --",true,"kept"]"#)
  }

  @Test func carriageReturnInsideSQLCommentCannotHidePrepareTimePragma() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE parents (id TEXT PRIMARY KEY)');
      LifeSql.run('CREATE TABLE children (parent TEXT REFERENCES parents(id))');
      let rejected = false;
      try { LifeSql.all("SELECT 1 --\\r'\\n; PRAGMA foreign_keys=OFF; --'\\n"); }
      catch { rejected = true; }
      let enforced = false;
      try { LifeSql.run("INSERT INTO children VALUES ('absent')"); }
      catch { enforced = true; }
      JSON.stringify([rejected, enforced, LifeSql.all('SELECT count(*) AS n FROM children')[0].n]);
      """)
    #expect(context.exception == nil)
    #expect(result?.toString() == "[true,true,0]")
  }

  @Test func foreignKeyMetadataReadsPreserveConnectionAndWriteProtection() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE parents (id TEXT PRIMARY KEY)');
      LifeSql.run('CREATE TABLE children (parent TEXT REFERENCES parents(id) ON DELETE CASCADE)');
      LifeSql.run('CREATE TEMP TABLE temp_parents (id TEXT PRIMARY KEY)');
      LifeSql.run('CREATE TEMP TABLE temp_children (parent TEXT REFERENCES temp_parents(id) ON DELETE SET NULL)');
      const main = LifeSql.all('PRAGMA main.foreign_key_list("children")');
      const temp = LifeSql.all('PRAGMA temp.foreign_key_list("temp_children")');
      const rejected = [];
      for (const sql of [
          'PRAGMA foreign_keys=OFF', 'PRAGMA foreign_keys=ON',
          '/* prefix */ PRAGMA main.foreign_keys(OFF)',
          'SELECT 1; PRAGMA foreign_keys=OFF',
          'PRAGMA query_only=OFF', 'ATTACH DATABASE \":memory:\" AS extra',
          'SELECT * FROM pragma_foreign_keys(0)', 'SELECT * FROM pragma_query_only(0)',
          'SELECT * FROM pragma_writable_schema(1)', "SELECT * FROM pragma_journal_mode('OFF')"
      ]) {
          try { LifeSql.all(sql); rejected.push(false); } catch { rejected.push(true); }
      }
      let protectedForeignKey = false;
      try { LifeSql.run("INSERT INTO children VALUES ('absent')"); }
      catch { protectedForeignKey = true; }
      JSON.stringify([main[0].table, main[0].on_delete, temp[0].table, temp[0].on_delete,
          rejected, protectedForeignKey, LifeSql.all('SELECT count(*) AS n FROM children')[0].n]);
      """)
    #expect(context.exception == nil)
    #expect(
      result?.toString()
        == #"["parents","CASCADE","temp_parents","SET NULL",[true,true,true,true,true,true,true,true,true,true],true,0]"#
    )
  }

  @Test func repeatedColumnNamesDoNotCrashTheHost() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    #expect(
      context.evaluateScript("LifeSql.all('SELECT 1 AS value, 2 AS value')[0].value")?.toInt32()
        == 2)
  }

  @Test func javaScriptReadsAndWritesRealSQLite() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT, priority INTEGER, extra TEXT)');
      const changed = LifeSql.run('INSERT INTO notes VALUES (?,?,?,?)',
          ['fixture-1', "A quote ' stays data", 2, null]);
      const row = LifeSql.all('SELECT * FROM notes WHERE id=?', ['fixture-1'])[0];
      JSON.stringify([changed, row.id, row.title, row.priority, row.extra]);
      """)
    #expect(context.exception == nil)
    #expect(result?.toString() == #"[1,"fixture-1","A quote ' stays data",2,null]"#)
  }

  @Test func batchRollsBackOnConstraintFailureAndRemainsUsable() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE notes (id TEXT PRIMARY KEY)');
      let failed = false;
      try {
          LifeSql.batch([
              {sql: 'INSERT INTO notes VALUES (?)', params: ['same']},
              {sql: 'INSERT INTO notes VALUES (?)', params: ['same']}
          ]);
      } catch { failed = true; }
      const empty = LifeSql.all('SELECT * FROM notes').length === 0;
      LifeSql.batch([{sql: 'INSERT INTO notes VALUES (?)', params: ['kept']}]);
      failed && empty && LifeSql.all('SELECT id FROM notes')[0].id === 'kept';
      """)
    #expect(context.exception == nil)
    #expect(result?.toBool() == true)
  }

  @Test func rejectsBadParametersAndReadSideWrites() throws {
    let context = try #require(JSContext())
    try SQLiteBridge(path: ":memory:").install(in: context)
    let result = context.evaluateScript(
      """
      LifeSql.run('CREATE TABLE notes (id TEXT PRIMARY KEY)');
      let failures = 0;
      for (const value of [true, {}, [1], Infinity, NaN, undefined]) {
          try { LifeSql.run('INSERT INTO notes VALUES (?)', [value]); }
          catch { failures++; }
      }
      try { LifeSql.all('INSERT INTO notes VALUES (?)', ['bad']); }
      catch { failures++; }
      failures === 7 && LifeSql.all('SELECT * FROM notes').length === 0;
      """)
    #expect(context.exception == nil)
    #expect(result?.toBool() == true)
  }

  @Test func fileBackedDatabaseSurvivesReopening() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      let context = try #require(JSContext())
      let bridge = try SQLiteBridge(path: url.path)
      try bridge.install(in: context)
      context.evaluateScript(
        "LifeSql.run('CREATE TABLE notes (id TEXT)'); LifeSql.run('INSERT INTO notes VALUES (?)', ['fixture-1']);"
      )
      #expect(context.exception == nil)
      try bridge.close()
      #expect(
        context.evaluateScript(
          "try { LifeSql.all('SELECT * FROM notes'); false; } catch { true; }")?.toBool() == true)
    }
    let context = try #require(JSContext())
    let bridge = try SQLiteBridge(path: url.path)
    defer { try? bridge.close() }
    try bridge.install(in: context)
    #expect(
      context.evaluateScript("LifeSql.all('SELECT id FROM notes')[0].id")?.toString() == "fixture-1"
    )
  }
}
