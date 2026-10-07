import Foundation
import SQLite3

public struct ExtensionReadError: Error, LocalizedError, Sendable {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct WidgetQueryResult: Sendable {
  public let rows: [CoreRow]
  public let effectiveDay: String?
  public let nextBoundary: Date?
}

/// An independent SQLite connection, with no registered host functions, credentials,
/// runtime, or writer. Never override GRDB's authorizer on the app's connection.
public struct WidgetPlanReader: Sendable {
  public let databaseURL: URL
  public let workLimit: Int
  public init(databaseURL: URL, workLimit: Int = 2_000_000) {
    self.databaseURL = databaseURL
    self.workLimit = workLimit
  }

  public func read(
    plan: CoreReadPlan, workspaceID: String, replicaID: String,
    now: Date = Date(), cancelled: @escaping () -> Bool = { false }
  ) throws -> WidgetQueryResult {
    guard plan.version == 1, exact(plan.workspaceID, workspaceID), exact(plan.replicaID, replicaID),
      plan.guards.contains(where: { $0.kind == "schema" }),
      plan.guards.contains(where: { $0.kind == "catalog" }), plan.guards.count <= 8,
      plan.viewID == nil || plan.guards.contains(where: { $0.kind == "view" }),
      plan.maximumRows == (plan.kind == .count ? 10001 : 20),
      !plan.columns.isEmpty, plan.columns.count <= 2, workLimit > 0,
      !cancelled(), (try JSONEncoder().encode(plan)).count <= 1_048_576
    else { throw failure }
    let calendar = try plan.calendarPolicy.map {
      try extensionCalendarContext(
        timeZone: $0.timeZone, now: now, dayStartMinutes: $0.dayStartMinutes)
    }
    var connection: OpaquePointer?
    guard
      sqlite3_open_v2(
        databaseURL.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let db = connection
    else {
      if let connection { sqlite3_close(connection) }
      throw failure
    }
    defer { sqlite3_close(db) }
    sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 262144)
    sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
    sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
    sqlite3_busy_timeout(db, 100)
    // The only transaction controls are trusted host code, before/after authorizer.
    guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure }
    defer {
      sqlite3_set_authorizer(db, nil, nil)
      sqlite3_progress_handler(db, 0, nil, nil)
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }
    let budget = Budget(remaining: workLimit, cancelled: cancelled)
    defer {
      sqlite3_progress_handler(db, 0, nil, nil)
      withExtendedLifetime(budget) {}
    }
    let pointer = Unmanaged.passUnretained(budget).toOpaque()
    sqlite3_progress_handler(
      db, 100,
      { raw in
        guard let raw else { return 1 }
        let budget = Unmanaged<Budget>.fromOpaque(raw).takeUnretainedValue()
        budget.remaining -= 100
        return budget.remaining <= 0 || budget.cancelled() ? 1 : 0
      }, pointer)
    sqlite3_set_authorizer(
      db,
      { _, action, _, second, database, _ in
        switch action {
        case SQLITE_SELECT, SQLITE_RECURSIVE: return SQLITE_OK
        case SQLITE_READ:
          return database == nil || String(cString: database!) == "main" ? SQLITE_OK : SQLITE_DENY
        case SQLITE_FUNCTION:
          guard let second else { return SQLITE_DENY }
          return [
            "length", "date", "julianday", "substr", "instr", "lower", "json_valid", "json_type",
            "json_array_length", "json_extract", "count", "sum",
          ].contains(String(cString: second).lowercased()) ? SQLITE_OK : SQLITE_DENY
        default: return SQLITE_DENY
        }
      }, nil)
    var bytes = 0
    for guardValue in plan.guards {
      let rows = try query(
        db, sql: guardValue.sql, parameters: guardValue.parameters, rowLimit: 4096, bytes: &bytes)
      guard sameRows(rows, guardValue.expectedRows) else { throw failure }
    }
    let parameters: [CoreSQLScalar] = try plan.parameters.map { parameter in
      switch parameter {
      case .literal(let literal): return literal.value
      case .calendar(let tagged):
        guard let calendar else { throw failure }
        switch tagged.slot {
        case .today: return .string(calendar.today)
        case .start: return .string(calendar.start)
        case .end: return .string(calendar.end)
        }
      }
    }
    let rows = try query(
      db, sql: plan.sql, parameters: parameters, rowLimit: plan.kind == .count ? 1 : 20,
      bytes: &bytes)
    guard !cancelled(),
      rows.allSatisfy({ row in
        row.count == plan.columns.count && plan.columns.allSatisfy { row[$0] != nil }
      })
    else { throw failure }
    if plan.kind == .count {
      guard rows.count == 1, case .number(let count) = rows[0]["count"], count >= 0, count <= 10001,
        count.rounded() == count
      else { throw failure }
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return WidgetQueryResult(
      rows: rows, effectiveDay: calendar?.today,
      nextBoundary: calendar.flatMap { formatter.date(from: $0.end) })
  }
}

private final class Budget {
  var remaining: Int
  let cancelled: () -> Bool
  init(remaining: Int, cancelled: @escaping () -> Bool) {
    self.remaining = remaining
    self.cancelled = cancelled
  }
}
private let failure = ExtensionReadError(
  message: "Widget data is unavailable. Open the app to refresh.")
private func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }

private func sameRows(_ left: [CoreRow], _ right: [CoreRow]) -> Bool {
  guard left.count == right.count else { return false }
  return zip(left, right).allSatisfy { lhs, rhs in
    lhs.count == rhs.count
      && lhs.allSatisfy { key, value in
        guard let pair = rhs.first(where: { exact(key, $0.key) }) else { return false }
        switch (value, pair.value) {
        case (.string(let a), .string(let b)): return exact(a, b)
        case (.number(let a), .number(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
      }
  }
}

private func query(
  _ db: OpaquePointer, sql: String, parameters: [CoreSQLScalar], rowLimit: Int, bytes: inout Int
) throws -> [CoreRow] {
  guard !sql.utf8.contains(0), sql.utf8.count <= 262144 else { throw failure }
  var statement: OpaquePointer?
  let result = try sql.withCString { text -> Int32 in
    var tail: UnsafePointer<CChar>?
    let result = sqlite3_prepare_v2(db, text, -1, &statement, &tail)
    if let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sqlite3_finalize(statement)
      statement = nil
      throw failure
    }
    return result
  }
  defer { sqlite3_finalize(statement) }
  guard result == SQLITE_OK, let statement, sqlite3_stmt_readonly(statement) != 0,
    sqlite3_bind_parameter_count(statement) == parameters.count
  else { throw failure }
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  for (offset, value) in parameters.enumerated() {
    let index = Int32(offset + 1)
    let result: Int32
    switch value {
    case .null: result = sqlite3_bind_null(statement, index)
    case .number(let number):
      guard number.isFinite else { throw failure }
      result = sqlite3_bind_double(statement, index, number)
    case .string(let text):
      guard text.utf8.count <= 262144 else { throw failure }
      result = text.withCString {
        sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient)
      }
    }
    guard result == SQLITE_OK else { throw failure }
  }
  var rows: [CoreRow] = []
  while true {
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { return rows }
    guard step == SQLITE_ROW, rows.count < rowLimit else { throw failure }
    var row: CoreRow = [:]
    for index in 0..<sqlite3_column_count(statement) {
      guard let name = sqlite3_column_name(statement, index) else { throw failure }
      let key = String(cString: name)
      guard row[key] == nil else { throw failure }
      switch sqlite3_column_type(statement, index) {
      case SQLITE_NULL: row[key] = .null
      case SQLITE_INTEGER, SQLITE_FLOAT:
        let number = sqlite3_column_double(statement, index)
        guard number.isFinite, abs(number) <= 9_007_199_254_740_991 else { throw failure }
        row[key] = .number(number)
      case SQLITE_TEXT:
        let length = Int(sqlite3_column_bytes(statement, index))
        bytes += length
        guard bytes <= 1_048_576, let pointer = sqlite3_column_text(statement, index),
          let text = String(
            bytes: UnsafeBufferPointer(start: pointer, count: length), encoding: .utf8)
        else { throw failure }
        row[key] = .string(text)
      default: throw failure
      }
    }
    rows.append(row)
  }
}
