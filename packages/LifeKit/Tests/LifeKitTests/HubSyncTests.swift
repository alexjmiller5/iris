import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct HubSyncTests {
  @Test func editingAdvisoryTracksFullSyncMissingHistoryAndInterruptedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try LifeCoreRuntime()
    let hubPath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: hubPath, runtime: runtime)
    try await seed.createSample()
    runtime.context.evaluateScript(
      """
      LifeSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['fixture-title','notes','invariant',1,"SELECT id FROM changed WHERE title = 'Blocked'",'Fixture title is blocked.']);
      LifeSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['fixture-view','views','invariant',1,"SELECT id FROM changed WHERE name = 'Blocked'",'Fixture view is blocked.']);
      """)
    #expect(runtime.context.exception == nil)
    try await seed.close()
    try HubFixture.state.load(path: hubPath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let transport = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") },
      makeTransport: { _ in transport })
    try await model.connect(
      HubCredentials(endpoint: transport.endpoint, token: "fixture-scoped-token"), remember: false)
    model.table = "notes"
    await model.reload()
    #expect(model.canWrite)
    #expect(model.editingUnavailable == nil)
    let client = try #require(model.client)
    let context = try #require(model.editingContext)
    let original = try #require(model.rows.first?.record)
    try await model.refreshSavedViews(context: context)
    #expect(model.viewsWriteability?.writable == true)
    do {
      try await model.save(
        ["id": original["id"]!, "title": .string("Blocked")], original: original, context: context)
      Issue.record("An invariant-violating edit was accepted")
    } catch let error as WorkspaceError {
      #expect(error.violations.first?.rule == "fixture-title")
    }
    #expect(try await client.rows(table: "notes").first?.record == original)
    #expect(try await client.status().pendingUiEdits == 0)
    _ = try await model.save(
      ["id": original["id"]!, "title": .string("Allowed")], original: original, context: context)
    await model.synchronize()
    #expect(model.canWrite)
    #expect(
      HubFixture.state.record(table: "notes", id: original["id"]!.text)?["title"]
        == .string("Allowed"))

    _ = try await client.sync(using: transport, tables: ["history": false])
    await model.reload()
    #expect(!model.canWrite)
    #expect(model.editingUnavailable?.contains("history") == true)
    #expect(model.rows.first?.label == "Allowed")
    try await model.refreshSavedViews(context: context)
    #expect(model.viewsWriteability?.writable == false)
    await model.synchronize()
    #expect(model.canWrite)
    HubFixture.state.failPull("notes")
    await model.synchronize()
    #expect(!model.canWrite)
    #expect(model.error?.contains("503") == true)
    #expect(model.editingUnavailable?.contains("incomplete") == true)
    #expect(model.rows.first?.label == "Allowed")
    await #expect(throws: WorkspaceError.self) {
      try await model.save(
        ["id": original["id"]!, "title": .string("Unsafe")], original: nil, context: context)
    }
    HubFixture.state.failPull(nil)
    await model.synchronize()
    #expect(model.canWrite)
    model.table = "history"
    #expect(!model.canWrite)
    await model.reload()
    #expect(!model.canWrite)
    #expect(model.writeability?.reason?.rule == "read_only")
    #expect(!model.rows.isEmpty)
    await model.close()
    #expect(!model.canWrite)
  }

  @Test func realCorePullEditPushAndTransportFailureRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixturePath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: fixturePath)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: fixturePath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let transport = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let path = directory.appendingPathComponent("replica.sqlite").path
    let replica = try NativeWorkspace(path: path)
    let first = try await replica.sync(using: transport)
    #expect(first.pulled > 0)
    #expect(first.rejected.isEmpty)
    #expect(try await replica.status().pendingUiEdits == 0)
    let row = try #require(try await replica.rows(table: "notes").first)
    _ = try await replica.write(
      table: "notes",
      patch: [
        "id": .string(row.id), "body": .string("# Native sync\n\nShared core, synthetic data."),
      ], expectedUpdatedAt: row.record["updated_at"]?.text)
    #expect(try await replica.status().pendingUiEdits == 1)
    HubFixture.state.setStatus(401)
    await #expect(throws: Error.self) { try await replica.sync(using: transport) }
    #expect(try await replica.status().pendingUiEdits == 1)
    HubFixture.state.setStatus(200)
    let second = try await replica.sync(using: transport)
    #expect(try await replica.status().pendingUiEdits == 0)
    #expect(try await replica.status().lastSuccessfulSync != nil)
    #expect(second.pushed > 0)
    #expect(
      HubFixture.state.record(table: "notes", id: row.id)?["body"]
        == .string("# Native sync\n\nShared core, synthetic data."))
    #expect(HubFixture.state.rowCount(table: "history") == 1)
    let lock = try SyncFileLock(databasePath: path)
    await #expect(throws: Error.self) { try await replica.sync(using: transport) }
    withExtendedLifetime(lock) {}
    try await replica.close()
  }

  @Test func errorsDoNotExposeResponseBodiesOrCredentialsAndReleaseLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let path = directory.appendingPathComponent("replica.sqlite").path
    let replica = try NativeWorkspace(path: path)
    for status in [401, 302, 500] {
      HubFixture.state.setStatus(status)
      do {
        _ = try await replica.sync(using: hub)
        Issue.record("Failed response accepted")
      } catch {
        #expect(error.localizedDescription.contains("Hub HTTP \(status)"))
        #expect(!error.localizedDescription.contains("private-body"))
      }
      let lock = try SyncFileLock(databasePath: path)
      withExtendedLifetime(lock) {}
    }
    HubFixture.state.setStatus(200)
    #expect(try await replica.sync(using: hub).pulled > 0)
    try await replica.close()
  }
}

private final class HubFixture: URLProtocol, @unchecked Sendable {
  static let state = FixtureState()
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "fixture.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.state.reply(request)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "Date": formatter.string(from: Date())])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private final class FixtureState: @unchecked Sendable {
  private let lock = NSLock()
  private var tables: [String: [WorkspaceRecord]] = [:]
  private var schema: [WorkspaceRecord] = []
  private var status = 200
  private var failedPullTable: String?
  func setStatus(_ status: Int) { lock.withLock { self.status = status } }
  func failPull(_ table: String?) { lock.withLock { failedPullTable = table } }
  func record(table: String, id: String) -> WorkspaceRecord? {
    lock.withLock { tables[table]?.first { $0["id"]?.text == id } }
  }
  func rowCount(table: String) -> Int { lock.withLock { tables[table]?.count ?? 0 } }
  @MainActor func load(path: String) throws {
    try lock.withLock {
      let bridge = try SQLiteBridge(path: path)
      defer { try? bridge.close() }
      let context = try #require(JSContext())
      try bridge.install(in: context)
      func records(_ sql: String) throws -> [WorkspaceRecord] {
        let result = context.objectForKeyedSubscript("LifeSql")?.invokeMethod(
          "all", withArguments: [sql])
        let json = try #require(
          context.objectForKeyedSubscript("JSON")?.invokeMethod(
            "stringify", withArguments: [result as Any])?.toString())
        return try JSONDecoder().decode([WorkspaceRecord].self, from: Data(json.utf8))
      }
      schema = try records("SELECT applied_at,ddl FROM _schema_log ORDER BY id")
      for name in [
        "notes", "topics", "catalog_tables", "catalog_properties", "catalog_rules", "history",
        "views",
      ] {
        tables[name] = try records("SELECT * FROM \(name)")
      }
      status = 200
      failedPullTable = nil
    }
  }
  func reply(_ request: URLRequest) throws -> (Int, Data) {
    try lock.withLock {
      if status != 200 { return (status, Data(#"{"error":"private-body"}"#.utf8)) }
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-scoped-token",
        request.httpMethod == "POST"
      else { return (401, Data("{}".utf8)) }
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
      let table = body["table"]?.text ?? ""
      let data: JSONValue
      switch request.url!.path {
      case "/v1/schema/pull": data = .object(["entries": .array(schema.map(JSONValue.object))])
      case "/v1/stats":
        data = .object(["tables": .object(tables.mapValues { .number(Double($0.count)) })])
      case "/v1/cursor":
        data = .object([
          "max_hub_at": .string(""), "tables": .object(tables.mapValues { _ in .string("") }),
        ])
      case "/v1/rows/pull":
        if table == failedPullTable { return (503, Data("{}".utf8)) }
        data = .object(["rows": .array((tables[table] ?? []).map(JSONValue.object))])
      case "/v1/rows/push":
        guard case .array(let values) = body["rows"] else { throw URLError(.badServerResponse) }
        for case .object(let row) in values {
          tables[table]?.removeAll { $0["id"] == row["id"] }
          tables[table, default: []].append(row)
        }
        data = .object(["upserted": .number(Double(values.count)), "rejected": .array([])])
      default: throw URLError(.badURL)
      }
      return (200, try JSONEncoder().encode(data))
    }
  }
}
