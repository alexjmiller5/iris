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
    configuration.prepareDatabase { db in
      // Apple SQLite defaults to legacy rename behavior, unlike other hosts.
      // Replayed renames must update references inside triggers and views.
      try db.execute(sql: "PRAGMA legacy_alter_table = OFF")
    }
    database = try DatabaseQueue(path: path, configuration: configuration)
    try database.write { db in try Self.repairLegacyTimestampRenames(db) }
  }

  /// Recover only the exact timestamp trigger damaged by a previously logged
  /// legacy rename. This restores that DDL's intended effect without changing
  /// user rows, pending writes, or the schema log. Custom triggers stay untouched.
  private static func repairLegacyTimestampRenames(_ db: Database) throws {
    guard try db.tableExists("_schema_log") else { return }
    let log = try String.fetchAll(db, sql: "SELECT ddl FROM _schema_log")
    let normalize: (String) -> String = {
      $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    let logged = Set(log.map(normalize))
    let triggers = try Row.fetchAll(
      db, sql: "SELECT name,tbl_name,sql FROM sqlite_master WHERE type='trigger'")
    let identifier: (String) -> Bool = {
      $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
    for trigger in triggers {
      let name: String = trigger["name"]
      let table: String = trigger["tbl_name"]
      guard name.hasSuffix("_updated_at"), identifier(name), identifier(table) else { continue }
      let source = String(name.dropLast("_updated_at".count))
      guard identifier(source), source != table, try !db.tableExists(source),
        try !db.viewExists(source)
      else { continue }
      let quoted: (String) -> String = { "\"" + $0 + "\"" }
      let sourceForms = [source, quoted(source)]
      let targetForms = [table, quoted(table)]
      let hasRename = sourceForms.contains { old in
        targetForms.contains { new in
          let ddl = "ALTER TABLE \(old) RENAME TO \(new)"
          return logged.contains(ddl) || logged.contains(ddl + ";")
        }
      }
      guard hasRename else { continue }
      let sql = normalize(trigger["sql"] as String)
      var repaired: String?
      for quoteOriginal in [false, true] {
        let original: (String) -> String = { quoteOriginal ? quoted($0) : $0 }
        let prefix =
          "CREATE TRIGGER \(original(name)) AFTER UPDATE ON \(quoted(table)) FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE "
        let suffix =
          " SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid; END"
        if sql == prefix + original(source) + suffix {
          repaired = prefix + quoted(table) + suffix
        }
      }
      guard let repaired else { continue }
      try db.execute(sql: "DROP TRIGGER \(quoted(name))")
      try db.execute(sql: repaired)
    }
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
          function call(kind, statements, context) {
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
              const reply = JSON.parse(__lifeSql(JSON.stringify({kind, statements, context})));
              if (reply.error) throw new Error(reply.error);
              return reply.value;
          }
          return {
              all: (sql, params = []) => call('all', [{sql, params}]),
              run: (sql, params = []) => call('run', [{sql, params}]),
              batch: statements => call('batch', statements),
              readDependencies: (statements, context) => call('dependencies', statements, context),
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
      ["all", "run", "batch", "dependencies", "begin", "commit", "rollback"].contains(kind),
      ["begin", "commit", "rollback"].contains(kind)
        ? statements.isEmpty : (["batch", "dependencies"].contains(kind) || statements.count == 1)
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
    if kind == "dependencies" {
      guard let context = request["context"] as? [String: Any],
        let owned = context["ownedTempTables"] as? [String]
      else {
        throw LifeCoreRuntime.RuntimeError.invalidInput
      }
      for (sql, _) in commands { try validateRead(sql) }
      return try database.unsafeRead { db in
        try db.readOnly { try readDependencies(commands, owned: owned, db: db) }
      }
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

  /// GRDB keeps its authorizer installed. Public region membership identifies
  /// candidate reads; union/equality then proves no unknown region was omitted.
  private func readDependencies(
    _ commands: [(String, StatementArguments)], owned: [String], db: Database
  ) throws -> Any {
    guard db.isInsideTransaction else { return NSNull() }
    let databases = try Row.fetchAll(db, sql: "PRAGMA database_list")
    guard databases.allSatisfy({ ["main", "temp"].contains($0["name"] as String) }) else {
      return NSNull()
    }
    func folded(_ name: String) -> String {
      String(decoding: name.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
    let inventory = try Row.fetchAll(db, sql: "PRAGMA table_list")
    let main = inventory.filter { $0["schema"] as String == "main" }
    let tempObjects = try Row.fetchAll(db, sql: "SELECT type,name FROM temp.sqlite_schema")
    let ownedNames = Set(owned.map(folded))
    guard ownedNames.count == owned.count,
      tempObjects.count == ownedNames.count,
      tempObjects.allSatisfy({
        $0["type"] as String == "table" && ownedNames.contains(folded($0["name"]))
      }),
      !main.contains(where: { ownedNames.contains(folded($0["name"])) }),
      owned.allSatisfy({ name in
        inventory.contains { row in
          row["schema"] as String == "temp" && folded(row["name"]) == folded(name)
            && row["type"] as String == "table"
        }
      })
    else { return NSNull() }

    // GRDB currently folds Unicode, while SQLite folds only ASCII. Never let
    // two different schema objects collapse into one dependency (for example Ä/ä).
    let names = main.map { $0["name"] as String } + owned
    guard Set(names.map { $0.lowercased() }).count == names.count else { return NSNull() }

    var region = DatabaseRegion()
    for (sql, arguments) in commands {
      let statement = try db.makeStatement(sql: sql)
      guard statement.isReadonly else { throw LifeCoreRuntime.RuntimeError.invalidInput }
      try statement.setArguments(arguments)
      region = region.union(statement.databaseRegion)
    }
    guard !region.isFullDatabase else { return NSNull() }
    var accounted = DatabaseRegion()
    var tables: [String] = []
    for row in main {
      let name: String = row["name"]
      guard region.isModified(byEventsOfKind: .delete(tableName: name)) else { continue }
      let type: String = row["type"]
      guard !name.hasPrefix("_"), !folded(name).hasPrefix("sqlite_"),
        ["table", "view"].contains(type)
      else { return NSNull() }
      if type == "table" { tables.append(name) }
      accounted = accounted.union(try Table(name).databaseRegion(db))
    }
    let mainNames = Set(main.map { folded($0["name"]) })
    let contexts = ownedNames.contains("_core_write_before") ? ["changed", "before", "now"] : []
    for name in owned + contexts + ["json_each", "json_tree"]
    where !mainNames.contains(folded(name)) {
      if region.isModified(byEventsOfKind: .delete(tableName: name)) {
        accounted = accounted.union(try Table(name).databaseRegion(db))
      }
    }
    guard accounted.union(region) == accounted else { return NSNull() }
    return ["tables": tables.sorted()]
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
