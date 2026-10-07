import Foundation
import LifeExtensionSupport
import SQLite3
import Testing

@testable import LifeKit

struct WidgetPlanReaderTests {
  private func database(_ body: (URL, OpaquePointer) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    let connection = try #require(db)
    defer { sqlite3_close(connection) }
    #expect(
      sqlite3_exec(
        connection,
        "CREATE TABLE items(id TEXT PRIMARY KEY,name TEXT,due TEXT,deleted_at TEXT); INSERT INTO items VALUES ('a','first','2026-10-07',NULL),('b','second','2026-10-08',NULL)",
        nil, nil, nil) == SQLITE_OK)
    try body(url, connection)
  }

  private func plan(
    sql: String = "SELECT id,name FROM items WHERE due=? ORDER BY id LIMIT 20",
    parameters: [[String: Any]] = [["kind": "calendar", "slot": "today"]]
  ) throws -> CoreReadPlan {
    let value: [String: Any] = [
      "version": 1, "workspaceID": "workspace", "replicaID": "replica", "table": "items",
      "viewID": NSNull(), "viewUpdatedAt": NSNull(), "kind": "list", "sql": sql,
      "parameters": parameters,
      "columns": ["id", "name"], "displayColumn": "name", "maximumRows": 20,
      "calendarPolicy": ["timeZone": "UTC", "dayStartMinutes": 180],
      "guards": [
        [
          "kind": "catalog", "sql": "SELECT 'fixture' AS value", "parameters": [],
          "expectedRows": [["value": "fixture"]],
        ],
        [
          "kind": "schema", "sql": "SELECT 'schema-fixture' AS value", "parameters": [],
          "expectedRows": [["value": "schema-fixture"]],
        ],
      ],
    ]
    return try JSONDecoder().decode(
      CoreReadPlan.self, from: JSONSerialization.data(withJSONObject: value))
  }

  @Test func actualReadOnlySQLiteRebindsAtDayBoundary() throws {
    try database { url, _ in
      let reader = WidgetPlanReader(databaseURL: url)
      let before = try reader.read(
        plan: plan(), workspaceID: "workspace", replicaID: "replica",
        now: Date(timeIntervalSince1970: 1_791_428_399))
      let after = try reader.read(
        plan: plan(), workspaceID: "workspace", replicaID: "replica",
        now: Date(timeIntervalSince1970: 1_791_428_400))
      #expect(before.rows.first?["id"] == .string("a"))
      #expect(after.rows.first?["id"] == .string("b"))
      #expect(before.effectiveDay == "2026-10-07")
      #expect(after.effectiveDay == "2026-10-08")
      #expect(before.nextBoundary == Date(timeIntervalSince1970: 1_791_428_400))
    }
  }

  @Test func guardStringsUseExactBytesAndIdentityIsRequired() throws {
    try database { url, _ in
      let reader = WidgetPlanReader(databaseURL: url)
      var value = try plan()
      #expect(throws: (any Error).self) {
        try reader.read(plan: value, workspaceID: "other", replicaID: "replica")
      }
      value.guards[0].sql = "SELECT 'é' AS value"
      value.guards[0].expectedRows = [["value": .string("é")]]
      #expect(throws: (any Error).self) {
        try reader.read(plan: value, workspaceID: "workspace", replicaID: "replica")
      }
    }
  }

  @Test(arguments: [
    "DELETE FROM items", "PRAGMA user_version=2", "ATTACH ':memory:' AS extra", "BEGIN",
    "SELECT id,name FROM items; SELECT 1", "SELECT load_extension('x')",
  ])
  func refusesWritesConnectionChangesAndMultipleStatements(sql: String) throws {
    try database { url, connection in
      let reader = WidgetPlanReader(databaseURL: url)
      #expect(throws: (any Error).self) {
        try reader.read(
          plan: plan(sql: sql, parameters: []), workspaceID: "workspace", replicaID: "replica")
      }
      var statement: OpaquePointer?
      #expect(
        sqlite3_prepare_v2(connection, "SELECT count(*) FROM items", -1, &statement, nil)
          == SQLITE_OK)
      defer { sqlite3_finalize(statement) }
      #expect(sqlite3_step(statement) == SQLITE_ROW)
      #expect(sqlite3_column_int(statement, 0) == 2)
    }
  }

  @Test func cancelsExpensiveReadAndRejectsUnknownVersionOrMissingGuards() throws {
    try database { url, _ in
      let reader = WidgetPlanReader(databaseURL: url, workLimit: 1000)
      let expensive = try plan(
        sql:
          "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT sum(x) AS id,'title' AS name FROM n",
        parameters: [])
      let completed = try WidgetPlanReader(databaseURL: url, workLimit: 5_000_000).read(
        plan: expensive, workspaceID: "workspace", replicaID: "replica")
      #expect(completed.rows.first?["id"] == .number(5_000_050_000))
      #expect(throws: (any Error).self) {
        try reader.read(plan: expensive, workspaceID: "workspace", replicaID: "replica")
      }
      #expect(throws: (any Error).self) {
        try reader.read(
          plan: plan(), workspaceID: "workspace", replicaID: "replica", cancelled: { true })
      }
      var unknown = try plan()
      unknown.version = 2
      #expect(throws: (any Error).self) {
        try reader.read(plan: unknown, workspaceID: "workspace", replicaID: "replica")
      }
      unknown.version = 1
      unknown.guards = []
      #expect(throws: (any Error).self) {
        try reader.read(plan: unknown, workspaceID: "workspace", replicaID: "replica")
      }
    }
  }

  @MainActor @Test func actualCanonicalPlanExecutesAfterNativeHostCloses() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let workspace = try NativeWorkspace(path: url.path)
    try await workspace.createSample()
    let plan = try await workspace.prepareReadPlan(
      CorePrepareReadPlanArgs(
        workspaceID: "workspace", replicaID: "replica", table: "notes", kind: .list))
    let expected = try await workspace.rows(
      view: CoreView(table: "notes", columns: plan.columns, limit: 20))
    try await workspace.close()
    let decoded = try JSONDecoder().decode(CoreReadPlan.self, from: JSONEncoder().encode(plan))
    let actual = try WidgetPlanReader(databaseURL: url).read(
      plan: decoded, workspaceID: "workspace", replicaID: "replica")
    #expect(actual.rows == expected.map(\.record))
    #expect(!actual.rows.isEmpty)
    #expect(actual.rows.allSatisfy { $0["body"] == nil })
  }
}
