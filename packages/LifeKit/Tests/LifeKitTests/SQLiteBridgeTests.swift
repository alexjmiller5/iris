import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct SQLiteBridgeTests {
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
