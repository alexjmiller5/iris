import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

/// Uses the real JSC writer and SQLite, not a manufactured validation error.
@Suite(.serialized) @MainActor
struct CatalogRecordAcceptanceTests {
  @Test func rejectedRuleKeepsDraftAndStoredRevisionUntilCorrection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    try Self.seed(runtime)
    try await Self.establishCoverage(workspace, runtime: runtime)
    let writeability = try await workspace.writeability(table: "record_examples")
    try #require(
      writeability.writable, Comment(rawValue: writeability.reason?.message ?? "Not writable"))
    let properties = try await workspace.catalog().properties.filter {
      $0["tbl"] == .string("record_examples")
    }
    let original = try #require(try await workspace.rows(table: "record_examples").first?.record)
    let journal = EditorDraftStore(
      root: directory, workspace: directory.appendingPathComponent("test.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "record_examples", store: journal
    ) { patch, baseline in
      try await workspace.write(
        table: "record_examples", patch: patch, expectedUpdatedAt: baseline?["updated_at"]?.text)
    }
    let history = try Self.history(runtime)
    let pending = try await workspace.status().pendingUiEdits
    #expect(editor.draft.fields.contains { $0.id == "title" && $0.required })
    #expect(!editor.draft.fields.contains { ["locked", "computed"].contains($0.id) })
    editor.setValue("Blocked", for: "title")
    editor.setValue("Retained second edit", for: "detail")
    // Mutants: bypass the invariant, replace its message, or acknowledge a rejected patch.
    do {
      try await editor.saveAll()
      Issue.record("The real catalog invariant accepted the blocked title")
    } catch let error as WorkspaceError {
      #expect(
        error.violations.contains {
          $0.rule == "catalog-title" && $0.message == "Fixture title is blocked."
        })
    }
    #expect(editor.violations.contains { $0.message == "Fixture title is blocked." })
    #expect(editor.dirty)
    #expect(editor.draft.values["title"] == "Blocked")
    #expect(editor.draft.values["detail"] == "Retained second edit")
    #expect(editor.draft.original == original)
    #expect(try await workspace.rows(table: "record_examples").first?.record == original)
    #expect(try Self.history(runtime) == history)
    #expect(try await workspace.status().pendingUiEdits == pending)
    let retained = try #require(
      try journal.load(table: "record_examples", recordID: "catalog-record"))
    #expect(retained.draft.values["title"] == "Blocked")
    #expect(retained.draft.values["detail"] == "Retained second edit")
    #expect(retained.draft.original == original)
    editor.setValue("Allowed", for: "title")
    try await editor.saveAll()
    let saved = try #require(try await workspace.rows(table: "record_examples").first?.record)
    #expect(saved["title"] == .string("Allowed"))
    #expect(saved["detail"] == .string("Retained second edit"))
    #expect(saved["locked"] == .string("Immutable fixture value"))
    #expect(saved["computed"] == .string("Derived fixture value"))
    #expect(saved["updated_at"] != original["updated_at"])
    #expect(!editor.dirty && editor.violations.isEmpty)
    #expect(try journal.load(table: "record_examples", recordID: "catalog-record") == nil)
    try await workspace.close()
  }

  // Explicitly run this preparation test before the allocated native UI case.
  // A Mac fixture is a NEW external file. A simulator fixture must name its exact UDID.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_DATABASE"] != nil
        || ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] != nil))
  func prepareCatalogRecordUIFixture() async throws {
    let environment = ProcessInfo.processInfo.environment
    let runtime = try LifeCoreRuntime()
    let file: URL
    #if targetEnvironment(simulator)
      try #require(environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] == environment["SIMULATOR_UDID"])
      try #require(environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] != nil)
      file = try WorkspaceModel.localURL()
    #elseif os(macOS)
      let path = try #require(environment["LIFE_UI_TEST_CATALOG_DATABASE"])
      file = URL(fileURLWithPath: path)
      try #require(file.lastPathComponent == "catalog-acceptance.sqlite")
      try #require(
        !FileManager.default.fileExists(atPath: file.path),
        "Refuse to overwrite an existing database")
    #else
      return
    #endif
    let existed = FileManager.default.fileExists(atPath: file.path)
    let workspace = try NativeWorkspace(path: file.path, runtime: runtime)
    if !existed { try await workspace.createSample() }
    // Never modify existing records/fixtures when a preparation is accidentally repeated.
    try #require(
      !(try await workspace.catalog().tables.contains { $0["id"] == .string("record_examples") }))
    try Self.seed(runtime)
    try await Self.establishCoverage(workspace, runtime: runtime)
    let writeability = try await workspace.writeability(table: "record_examples")
    try #require(
      writeability.writable, Comment(rawValue: writeability.reason?.message ?? "Not writable"))
    try await workspace.close()
  }

  // The real core must issue its coverage certificates through a complete sync.
  // Do not manufacture _core_coverage rows or bypass the invariant write gate.
  private static func establishCoverage(_ workspace: NativeWorkspace, runtime: LifeCoreRuntime)
    async throws
  {
    let snapshot = runtime.context.evaluateScript(
      #"""
      JSON.stringify({
        schema: LifeSql.all('SELECT applied_at,ddl FROM _schema_log ORDER BY id'),
        tables: Object.fromEntries(LifeSql.all("SELECT name FROM sqlite_master WHERE type='table'")
          .filter(r => !r.name.startsWith('_') && !r.name.startsWith('sqlite_'))
          .map(r => [r.name, LifeSql.all('SELECT * FROM "'+r.name.replaceAll('"','""')+'" ORDER BY id')]))
      })
      """#)
    try #require(runtime.context.exception == nil)
    let bytes = Data(try #require(snapshot?.toString()).utf8)
    let source = try JSONDecoder().decode(CatalogAcceptanceHub.Snapshot.self, from: bytes)
    CatalogAcceptanceHub.install(source)
    defer { CatalogAcceptanceHub.clear() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogAcceptanceHub.self]
    let hub = try HubTransport(
      endpoint: "https://catalog-acceptance.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let result = try await workspace.sync(using: hub)
    try #require(result.skipped.isEmpty && result.rejected.isEmpty)
  }

  private static func history(_ runtime: LifeCoreRuntime) throws -> String {
    let value = runtime.context.evaluateScript(
      "JSON.stringify(LifeSql.all(\"SELECT * FROM history WHERE tbl='record_examples' ORDER BY id\"))"
    )
    try #require(runtime.context.exception == nil)
    return try #require(value?.toString())
  }

  private static func seed(_ runtime: LifeCoreRuntime) throws {
    runtime.context.evaluateScript(
      #"""
      const ddl = `CREATE TABLE record_examples (
        id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT,
        title TEXT, detail TEXT, state TEXT, locked TEXT, computed TEXT)`;
      LifeSql.run(ddl);
      LifeSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
      LifeSql.run("INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('record_examples','table','title','Synthetic catalog acceptance')");
      for (const [col,label,type,sort,required,description,options,immutable,derived] of [
        ['title','Title','text',0,1,'Short fixture title.',null,0,null],
        ['detail','Detail','text',1,0,'A second independent edit.',null,0,null],
        ['state','State','select',2,0,'Choose a fixture state.',JSON.stringify([{v:'Draft',d:'Still being prepared.'},{v:'Ready',d:'Ready for review.'}]),0,null],
        ['locked','Locked','text',3,0,'Set once by the creator.',null,1,null],
        ['computed','Computed','text',4,0,'Filled by the fixture derivation.',null,0,'fixture-derivation']
      ]) LifeSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort,required,description,options,immutable,derived_by) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        ['record_examples.'+col,'record_examples',col,label,type,sort,required,description,options,immutable,derived]);
      LifeSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['catalog-title','record_examples','invariant',1,"SELECT id FROM changed WHERE title='Blocked'",'Fixture title is blocked.']);
      LifeSql.run("INSERT INTO record_examples VALUES ('catalog-record','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z',NULL,NULL,'Catalog fixture','Original detail','Draft','Immutable fixture value','Derived fixture value')");
      """#)
    try #require(
      runtime.context.exception == nil,
      Comment(rawValue: runtime.context.exception?.toString() ?? "Fixture SQL failed"))
  }
}

// Isolated, in-process transport of the synthetic snapshot, following HubSyncTests.
// Only the hub is a fixture: schema import, coverage, rule evaluation and writes use core.
private final class CatalogAcceptanceHub: URLProtocol, @unchecked Sendable {
  struct Snapshot: Decodable, Sendable {
    let schema: [WorkspaceRecord]
    let tables: [String: [WorkspaceRecord]]
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var source: Snapshot?
  static func install(_ snapshot: Snapshot) { lock.withLock { source = snapshot } }
  static func clear() { lock.withLock { source = nil } }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "catalog-acceptance.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    do {
      guard let source = Self.lock.withLock({ Self.source }),
        request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-scoped-token",
        request.httpMethod == "POST"
      else { throw URLError(.badServerResponse) }
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          bytes.append(contentsOf: buffer[..<count])
        }
      }
      let body = try JSONDecoder().decode(WorkspaceRecord.self, from: bytes)
      let data: JSONValue
      switch request.url?.path {
      case "/v1/schema/pull":
        data = .object(["entries": .array(source.schema.map(JSONValue.object))])
      case "/v1/stats":
        data = .object(["tables": .object(source.tables.mapValues { .number(Double($0.count)) })])
      case "/v1/cursor":
        data = .object([
          "max_hub_at": .string(""),
          "tables": .object(source.tables.mapValues { _ in .string("") }),
        ])
      case "/v1/rows/pull":
        let rows = source.tables[body["table"]?.text ?? ""] ?? []
        let limit = Int(body["limit"]?.text ?? "1000") ?? 1000
        let page = Array(
          rows.filter {
            body["after"] == nil || ($0["id"]?.text ?? "") > (body["after"]?.text ?? "")
          }.prefix(limit))
        data = .object([
          "rows": .array(page.map(JSONValue.object)),
          "next_cursor": page.count == limit ? (page.last?["id"] ?? .null) : .null,
        ])
      case "/v1/rows/push":
        guard case .array(let rows) = body["rows"] else { throw URLError(.badServerResponse) }
        data = .object(["upserted": .number(Double(rows.count)), "rejected": .array([])])
      default: throw URLError(.badURL)
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "Date": formatter.string(from: Date())])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONEncoder().encode(data))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
}
