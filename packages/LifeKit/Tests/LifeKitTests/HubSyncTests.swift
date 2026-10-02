import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct HubSyncTests {
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
  func setStatus(_ status: Int) { lock.withLock { self.status = status } }
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
      for name in ["notes", "catalog_tables", "catalog_properties", "catalog_rules", "history"] {
        tables[name] = try records("SELECT * FROM \(name)")
      }
      status = 200
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
