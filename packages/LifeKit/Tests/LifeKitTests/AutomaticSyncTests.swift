import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct AutomaticSyncTests {
  @Test func editsDebounceAndCatchUpAgainAfterAnEditDuringHeldSync() async throws {
    let (model, directory) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let loop = Task { await model.runAutomaticSync(debounce: .milliseconds(40)) }
    await Task.yield()
    AutoSyncHub.holdNextPush()
    try await save(model, title: "First edit")
    try await save(model, title: "Second edit")
    try await waitUntil { AutoSyncHub.waiting }
    #expect(AutoSyncHub.rounds == 1)
    try await save(model, title: "Edit while uploading")
    #expect(AutoSyncHub.waiting)
    AutoSyncHub.release()
    try await waitUntil { AutoSyncHub.rounds == 2 && !model.syncing }
    #expect(model.rows.first?.record["title"] == .string("Edit while uploading"))
    #expect(AutoSyncHub.uploadedTitles == ["Second edit", "Edit while uploading"])
    #expect(try await model.client?.status().pendingUiEdits == 0)
    loop.cancel()
    await loop.value
    await model.close()
  }

  @Test func foregroundExitStopsDebounceAndReentrySendsPendingEdits() async throws {
    let (model, directory) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let loop = Task { await model.runAutomaticSync(debounce: .milliseconds(200)) }
    await Task.yield()
    try await save(model, title: "Saved before leaving")
    loop.cancel()
    await loop.value
    try await Task.sleep(for: .milliseconds(250))
    #expect(AutoSyncHub.rounds == 0)
    let resumed = Task { await model.runAutomaticSync(debounce: .milliseconds(20)) }
    try await waitUntil { AutoSyncHub.rounds == 1 && !model.syncing }
    resumed.cancel()
    await resumed.value
    await model.close()
  }

  @Test func periodicCatchUpBacksOffAfterCancellationAndStopsWhenClosed() async throws {
    let (model, directory) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    AutoSyncHub.holdNextSchema()
    let loop = Task {
      await model.runAutomaticSync(interval: .milliseconds(30), debounce: .milliseconds(20))
    }
    try await waitUntil { AutoSyncHub.waiting }
    try await save(model, title: "Still local")
    model.cancelSync()
    try await waitUntil { !model.syncing }
    try await Task.sleep(for: .milliseconds(150))
    #expect(AutoSyncHub.rounds == 1, "Cancel must not immediately start another automatic round")
    #expect(model.rows.first?.record["title"] == .string("Still local"))
    #expect(model.error == nil, "Intentional cancellation is not a connection failure")
    await model.close()
    await loop.value
    try await Task.sleep(for: .milliseconds(80))
    #expect(AutoSyncHub.rounds == 1)
    AutoSyncHub.release()
  }

  @Test func reentryDuringAnActivePeriodicRoundKeepsTheNewForegroundLoop() async throws {
    let (model, directory) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    AutoSyncHub.holdNextSchema()
    let old = Task { await model.runAutomaticSync(interval: .milliseconds(30)) }
    try await waitUntil { AutoSyncHub.waiting }
    old.cancel()
    let current = Task {
      await model.runAutomaticSync(interval: .seconds(10), debounce: .milliseconds(20))
    }
    await Task.yield()
    AutoSyncHub.release()
    await old.value
    try await Task.sleep(for: .milliseconds(80))
    #expect(AutoSyncHub.rounds == 1)
    try await save(model, title: "Saved after returning")
    try await waitUntil { AutoSyncHub.rounds == 2 && !model.syncing }
    #expect(AutoSyncHub.uploadedTitles.last == "Saved after returning")
    current.cancel()
    await current.value
    await model.close()
  }

  private func save(_ model: WorkspaceModel, title: String) async throws {
    let row = try #require(model.rows.first?.record)
    _ = try await model.save(
      ["id": row["id"]!, "title": .string(title)], original: row, context: model.editingContext)
  }

  private func fixture() async throws -> (WorkspaceModel, URL) {
    AutoSyncHub.reset()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AutoSyncHub.self]
    let hub = try HubTransport(
      endpoint: "https://automatic-sync.invalid", token: "fixture", configuration: configuration)
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub })
    try await model.connect(
      HubCredentials(endpoint: hub.endpoint, token: "fixture"), remember: false,
      synchronizeAfter: false)
    try await #require(model.client).createSample()
    model.catalog = try await #require(model.client).catalog()
    model.table = "notes"
    await model.reload()
    await model.synchronize()
    try #require(model.error == nil)
    AutoSyncHub.reset()
    return (model, directory)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
  }
}

private final class AutoSyncHub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var count = 0
  nonisolated(unsafe) private static var holdRoute: String?
  nonisolated(unsafe) private static var titles: [String] = []
  private var savedBytes: Data?
  nonisolated(unsafe) private static var held: AutoSyncHub?
  static var uploadedTitles: [String] { lock.withLock { titles } }
  static var rounds: Int { lock.withLock { count } }
  static var waiting: Bool { lock.withLock { held != nil } }
  static func reset() {
    lock.withLock {
      count = 0
      holdRoute = nil
      titles = []
      held = nil
    }
  }
  static func holdNextSchema() { lock.withLock { holdRoute = "/v1/schema/pull" } }
  static func holdNextPush() { lock.withLock { holdRoute = "/v1/rows/push" } }
  static func release() {
    let pending = lock.withLock {
      let pending = held
      held = nil
      return pending
    }
    pending?.respond()
  }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "automatic-sync.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() { Self.lock.withLock { if Self.held === self { Self.held = nil } } }
  override func startLoading() {
    if request.url?.path == "/v1/schema/pull" { Self.lock.withLock { Self.count += 1 } }
    respond()
  }
  private func respond() {
    do {
      var bytes = savedBytes ?? request.httpBody ?? Data()
      if savedBytes == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n <= 0 { break }
          bytes.append(contentsOf: buffer[..<n])
        }
      }
      let body =
        bytes.isEmpty ? [:] : try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      savedBytes = bytes
      if Self.lock.withLock({
        guard Self.holdRoute == request.url?.path else { return false }
        Self.holdRoute = nil
        Self.held = self
        return true
      }) {
        return
      }
      if request.url?.path == "/v1/rows/push", body["table"] as? String == "notes" {
        let submitted = (body["rows"] as! [[String: Any]]).compactMap { $0["title"] as? String }
        Self.lock.withLock { Self.titles.append(contentsOf: submitted) }
      }
      let data: [String: Any]
      switch request.url!.path {
      case "/v1/session": data = ["name": "Fixture", "scopes": ["full"]]
      case "/v1/schema/pull": data = ["entries": []]
      case "/v1/schema/push": data = [:]
      case "/v1/stats":
        data = [
          "tables": Dictionary(
            uniqueKeysWithValues: [
              "notes", "topics", "catalog_tables", "catalog_properties", "catalog_rules", "history",
              "views",
            ].map { ($0, 1) })
        ]
      case "/v1/cursor":
        data = [
          "max_hub_at": "",
          "tables": Dictionary(
            uniqueKeysWithValues: (body["tables"] as! [String]).map { ($0, "") }),
        ]
      case "/v1/rows/pull": data = ["rows": [], "next_cursor": NSNull()]
      case "/v1/rows/push": data = ["upserted": (body["rows"] as! [Any]).count, "rejected": []]
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
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: data))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
}
