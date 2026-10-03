import Foundation
import GRDB
import JavaScriptCore

/// Trusted SQL primitives. NativeWorkspace serializes callers across async transactions.
@MainActor
public final class SQLiteBridge {
  private let database: DatabaseQueue

  public init(path: String) throws {
    var configuration = Configuration()
    configuration.allowsUnsafeTransactions = true
    database = try DatabaseQueue(path: path, configuration: configuration)
  }

  public func close() throws { try database.close() }

  /// Install only in a trusted core context, never a web page or user script.
  public func install(in context: JSContext) throws {
    let call: @convention(block) (String) -> String = { [self] json in
      do {
        return try encode(["value": execute(json)])
      } catch {
        // A fixed envelope always remains valid JSON, even for SQL errors.
        return (try? encode(["error": String(describing: error)]))
          ?? #"{"error":"SQL bridge failed"}"#
      }
    }
    context.setObject(call, forKeyedSubscript: "__lifeSql" as NSString)
    context.exception = nil
    context.evaluateScript(
      """
      globalThis.LifeSql = (() => {
          function call(kind, statements) {
              if (!Array.isArray(statements)) throw new Error('Expected SQL statements');
              for (const s of statements) {
                  if (!s || typeof s.sql !== 'string' || !Array.isArray(s.params ?? []))
                      throw new Error('Invalid SQL statement');
                  for (const p of s.params ?? []) {
                      if (p !== null && typeof p !== 'string' &&
                          !(typeof p === 'number' && Number.isFinite(p) &&
                            (!Number.isInteger(p) || Number.isSafeInteger(p))))
                          throw new Error('Invalid SQL parameter');
                  }
              }
              const reply = JSON.parse(__lifeSql(JSON.stringify({kind, statements})));
              if (reply.error) throw new Error(reply.error);
              return reply.value;
          }
          return {
              all: (sql, params = []) => call('all', [{sql, params}]),
              run: (sql, params = []) => call('run', [{sql, params}]),
              batch: statements => call('batch', statements),
              begin: () => call('begin', []),
              commit: () => call('commit', []),
              rollback: () => call('rollback', [])
          };
      })();
      """)
    if let exception = context.exception {
      throw LifeCoreRuntime.RuntimeError.javaScript(exception.toString())
    }
  }

  private func execute(_ json: String) throws -> Any {
    guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let kind = request["kind"] as? String,
      let statements = request["statements"] as? [[String: Any]],
      ["all", "run", "batch", "begin", "commit", "rollback"].contains(kind),
      ["begin", "commit", "rollback"].contains(kind)
        ? statements.isEmpty : (kind == "batch" || statements.count == 1)
    else { throw LifeCoreRuntime.RuntimeError.invalidInput }

    let commands = try statements.map { statement -> (String, StatementArguments) in
      guard let sql = statement["sql"] as? String,
        let params = (statement["params"] ?? []) as? [Any],
        params.allSatisfy({ value in
          if value is NSNull || value is String { return true }
          guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
          else { return false }
          return number.doubleValue.isFinite && abs(number.doubleValue) <= 9_007_199_254_740_991
        }),
        let arguments = StatementArguments(params)
      else { throw LifeCoreRuntime.RuntimeError.invalidInput }
      return (sql, arguments)
    }

    if ["begin", "commit", "rollback"].contains(kind) {
      try database.writeWithoutTransaction { db in
        switch kind {
        case "begin": try db.beginTransaction(.immediate)
        case "commit": try db.commit()
        default: try db.rollback()
        }
      }
      return NSNull()
    }
    if kind == "all" {
      try validateRead(commands[0].0)
      return try database.unsafeRead { db in
        try db.readOnly {
          let statement = try db.makeStatement(sql: commands[0].0)
          guard statement.isReadonly else { throw LifeCoreRuntime.RuntimeError.invalidInput }
          return try Row.fetchAll(statement, arguments: commands[0].1).map { row in
            try Dictionary(
              row.map { name, value in (name, try jsonValue(value)) },
              uniquingKeysWith: { _, last in last })
          }
        }
      }
    }
    let executeCommands: (Database) throws -> [Int] = { db in
      try commands.map { sql, arguments in
        let statement = try db.makeStatement(sql: sql)
        try statement.execute(arguments: arguments)
        return db.changesCount
      }
    }
    let changes: [Int] = try database.writeWithoutTransaction { db in
      if kind == "run", db.isInsideTransaction { return try executeCommands(db) }
      var result: [Int] = []
      try db.inSavepoint {
        result = try executeCommands(db)
        return .commit
      }
      return result
    }
    return kind == "run" ? changes[0] : changes
  }

  /// GRDB owns SQLite's authorizer. Reject connection control and extra statements
  /// before preparation: some PRAGMAs act during prepare, before readOnly can help.
  private func validateRead(_ sql: String) throws {
    guard !sql.contains("\0") else { throw LifeCoreRuntime.RuntimeError.invalidInput }
    var tokens = try readTokens(sql)
    if tokens.last == ";" { tokens.removeLast() }
    guard !tokens.contains(";"), let first = tokens.first?.lowercased() else {
      throw LifeCoreRuntime.RuntimeError.invalidInput
    }
    func identifier(_ token: String) -> String {
      token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]")).lowercased()
    }
    for index in tokens.indices.dropLast() {
      if identifier(tokens[index]) == "load_extension", tokens[index + 1] == "(" {
        throw LifeCoreRuntime.RuntimeError.invalidInput
      }
    }
    if ["select", "with", "values"].contains(first) { return }
    guard first == "pragma" else { throw LifeCoreRuntime.RuntimeError.invalidInput }
    tokens.removeFirst()
    if tokens.count >= 2, tokens[1] == "." {
      guard ["main", "temp"].contains(identifier(tokens[0])) else {
        throw LifeCoreRuntime.RuntimeError.invalidInput
      }
      tokens.removeFirst(2)
    }
    guard let name = tokens.first.map(identifier) else {
      throw LifeCoreRuntime.RuntimeError.invalidInput
    }
    if name == "data_version", tokens.count == 1 { return }
    guard ["table_info", "table_xinfo", "foreign_key_list"].contains(name),
      tokens.count == 4, tokens[1] == "(", tokens[3] == ")"
    else { throw LifeCoreRuntime.RuntimeError.invalidInput }
  }

  /// A single pass keeps unterminated comments/quotes linear. SQLite line
  /// comments end at LF, not CR; quoted delimiters never split statements.
  private func readTokens(_ sql: String) throws -> [String] {
    let bytes = Array(sql.utf8)
    var index = 0
    var tokens: [String] = []
    func word(_ byte: UInt8) -> Bool {
      byte >= 128 || (65...90).contains(byte) || (97...122).contains(byte)
        || (48...57).contains(byte) || byte == 95 || byte == 36
    }
    while index < bytes.count {
      let start = index
      let byte = bytes[index]
      if [9, 10, 12, 13, 32].contains(byte) {
        index += 1
        continue
      }
      if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 45 {
        index += 2
        while index < bytes.count, bytes[index] != 10 { index += 1 }
        continue
      }
      if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
        index += 2
        while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 47) {
          index += 1
        }
        guard index + 1 < bytes.count else { throw LifeCoreRuntime.RuntimeError.invalidInput }
        index += 2
        continue
      }
      if [39, 34, 96, 91].contains(byte) {
        let end: UInt8 = byte == 91 ? 93 : byte
        index += 1
        var closed = false
        while index < bytes.count {
          if bytes[index] == end {
            index += 1
            if byte != 91, index < bytes.count, bytes[index] == end {
              index += 1
              continue
            }
            closed = true
            break
          }
          index += 1
        }
        guard closed else { throw LifeCoreRuntime.RuntimeError.invalidInput }
      } else if word(byte) {
        repeat { index += 1 } while index < bytes.count && word(bytes[index])
      } else {
        index += 1
      }
      tokens.append(String(decoding: bytes[start..<index], as: UTF8.self))
    }
    return tokens
  }

  private func jsonValue(_ value: DatabaseValue) throws -> Any {
    switch value.storage {
    case .null: return NSNull()
    case .string(let value): return value
    case .int64(let value) where (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value):
      return value
    case .double(let value) where value.isFinite: return value
    default: throw LifeCoreRuntime.RuntimeError.invalidResult
    }
  }

  private func encode(_ value: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
  }
}
