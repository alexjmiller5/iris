import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct ForegroundSyncTests {
  @Test func backgroundGETDoesNotBlockLocalWorkOrBorrowSyncTransport() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let syncHub = try transport()
    let sync = Task { try await workspace.sync(using: syncHub) }
    try await waitUntil { HeldSyncTransport.isWaiting }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldSyncTransport.self]
    let serviceHub = try HubTransport(
      endpoint: "https://held-service.invalid", token: "service-fixture",
      configuration: configuration)
    let service = Task { try await workspace.notifications(using: serviceHub) }
    try await waitUntil { HeldSyncTransport.isWaiting(host: "held-service.invalid") }
    var readFinished = false
    let read = Task {
      let rows = try await workspace.rows(table: "notes")
      #expect(!rows.isEmpty)
      readFinished = true
    }
    try await waitUntil { readFinished }
    HeldSyncTransport.release(host: "held-service.invalid")
    _ = await service.result
    #expect(HeldSyncTransport.isWaiting)
    HeldSyncTransport.release()
    _ = await sync.result
    try await read.value
    try await workspace.close()
  }
  @Test func modelPublishesProgressAndClearsItAfterCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hub = try transport()
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub })
    try await model.connect(
      HubCredentials(endpoint: hub.endpoint, token: "fixture"), remember: false,
      synchronizeAfter: false)
    try await #require(model.client).createSample()
    model.catalog = try await #require(model.client).catalog()
    model.table = "notes"
    await model.reload()
    #expect(model.canWrite)
    let sync = Task { await model.synchronize() }
    try await waitUntil { HeldSyncTransport.isWaiting }
    #expect(model.syncing)
    #expect(model.canWrite, "Starting transport must not disable an already editable local table")
    #expect(model.syncProgress?.phase == "Schema")
    model.cancelSync()
    await sync.value
    #expect(!model.syncing && model.syncProgress == nil)
    #expect(!(try await #require(model.client).rows(table: "notes")).isEmpty)
    HeldSyncTransport.release()
    await model.close()
  }
  @Test func cancellationUnwindsHeldTransportAndKeepsLocalData() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let before = try await workspace.rows(table: "notes")
    let hub = try transport()
    var progress: [WorkspaceSyncProgress] = []
    let sync = Task { try await workspace.sync(using: hub, onProgress: { progress.append($0) }) }
    try await waitUntil { HeldSyncTransport.isWaiting }
    workspace.cancelSync()
    let result = await sync.result
    if case .success = result { Issue.record("Cancelled sync completed successfully") }
    #expect(progress.first?.phase == "Connecting")
    #expect(progress.last?.phase == "Schema")
    #expect(try await workspace.rows(table: "notes") == before)
    HeldSyncTransport.release()
    try await workspace.close()
  }

  @Test func totalDeadlineCancelsHeldTransport() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    let hub = try transport()
    let result = await Task { try await workspace.sync(using: hub, timeout: .milliseconds(30)) }
      .result
    if case .success = result { Issue.record("Deadline was ignored") }
    HeldSyncTransport.release()
    try await workspace.close()
  }

  private func transport() throws -> HubTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldSyncTransport.self]
    return try HubTransport(
      endpoint: "https://held-sync.invalid", token: "fixture", configuration: configuration)
  }
  private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
  }

  @Test func responseCannotResumeSyncInsideAWholeForegroundTransaction() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    var syncFinished = false
    let hub = try transport()
    let sync = Task {
      defer { syncFinished = true }
      return try await workspace.sync(using: hub)
    }
    try await waitUntil { HeldSyncTransport.isWaiting }
    runtime.context.evaluateScript(
      #"""
      const originalRequest = LifeNative.request;
      let holdingForeground = false;
      LifeNative.request = function(id, method, args) {
        if (method !== 'catalog') return originalRequest(id, method, args);
        LifeSql.begin();
        LifeSql.run('CREATE TABLE foreground_atomic (value TEXT)');
        LifeSql.run("INSERT INTO foreground_atomic VALUES ('complete')");
        holdingForeground = true;
        globalThis.releaseForeground = () => {
          LifeSql.commit();
          holdingForeground = false;
          originalRequest(id, method, args);
        };
      };
      """#)
    let foreground = Task { try await workspace.catalog() }
    try await waitUntil { runtime.context.evaluateScript("holdingForeground")?.toBool() == true }
    HeldSyncTransport.release()
    // Deliver the URLSession response while the foreground transaction stays owned.
    try await Task.sleep(for: .milliseconds(50))
    #expect(!syncFinished)
    #expect(runtime.context.evaluateScript("holdingForeground")?.toBool() == true)
    runtime.context.evaluateScript("releaseForeground()")
    _ = try await foreground.value
    _ = await sync.result
    #expect(syncFinished)
    #expect(runtime.context.exception == nil)
    try await workspace.close()
  }

  @Test func secondSyncAndCloseWaitForTheSuspendedOwner() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let hub = try transport()
    let first = Task { try await workspace.sync(using: hub) }
    try await waitUntil { HeldSyncTransport.isWaiting }
    var secondFinished = false
    let second = Task {
      defer { secondFinished = true }
      return try await workspace.sync(using: hub)
    }
    await Task.yield()
    var localFinished = false
    let local = Task {
      let row = try #require(try await workspace.rows(table: "notes").first)
      _ = try await workspace.write(
        table: "notes", patch: ["id": .string(row.id), "title": .string("Ahead of queued sync")])
      localFinished = true
    }
    try await waitUntil { localFinished }
    var closed = false
    let close = Task {
      try await workspace.close()
      closed = true
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!secondFinished && !closed)
    HeldSyncTransport.release()
    _ = await first.result
    try await waitUntil { HeldSyncTransport.isWaiting }
    #expect(!closed)
    HeldSyncTransport.release()
    _ = await second.result
    try await local.value
    try await close.value
    #expect(closed)
  }

  @Test func syncHTTPInsideATransactionFailsWithoutReleasingOwnership() async throws {
    defer { HeldSyncTransport.release() }
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    runtime.context.evaluateScript(
      #"""
      LifeNative.request = function(id, method, args) {
        LifeSql.begin();
        __lifePost('/v1/schema/pull', '{}', response => {
          LifeSql.rollback();
          __lifeFinish(id, response);
        });
      };
      """#)
    await #expect(throws: WorkspaceError.self) {
      try await workspace.sync(using: transport(), timeout: .milliseconds(30))
    }
    #expect(!HeldSyncTransport.isWaiting)
    try await workspace.close()
  }

  @Test func cachedReadAndSaveFinishWhileSyncTransportIsHeld() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("replica.sqlite").path
    let workspace = try NativeWorkspace(path: path)
    try await workspace.createSample()
    let before = try #require(try await workspace.rows(table: "notes").first)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldSyncTransport.self]
    let transport = try HubTransport(
      endpoint: "https://held-sync.invalid", token: "fixture", configuration: configuration)
    let sync = Task { try await workspace.sync(using: transport) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !HeldSyncTransport.isWaiting && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(HeldSyncTransport.isWaiting)
    var finished = false
    let foreground = Task {
      let catalog = try await workspace.catalog()
      #expect(!catalog.tables.isEmpty)
      #expect(try await workspace.rows(table: "notes").contains { $0.id == before.id })
      _ = try await workspace.write(
        table: "notes", patch: ["id": .string(before.id), "title": .string("Saved during sync")],
        expectedUpdatedAt: before.record["updated_at"]?.text)
      finished = true
    }
    let foregroundDeadline = clock.now.advanced(by: .seconds(2))
    while !finished && clock.now < foregroundDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(
      finished, "Local catalog, rows and save must finish before the HTTP response is released")
    #expect(throws: (any Error).self) { try SyncFileLock(databasePath: path) }
    HeldSyncTransport.release()
    _ = await sync.result
    try await foreground.value
    #expect(
      try await workspace.rows(table: "notes").first { $0.id == before.id }?.record["title"]
        == .string("Saved during sync"))
    try await workspace.close()
  }
}

private final class HeldSyncTransport: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pending: [String: HeldSyncTransport] = [:]
  static var isWaiting: Bool { isWaiting(host: "held-sync.invalid") }
  static func isWaiting(host: String) -> Bool { lock.withLock { pending[host] != nil } }
  static func release(host: String = "held-sync.invalid") {
    let request = lock.withLock { pending.removeValue(forKey: host) }
    request?.client?.urlProtocol(request!, didFailWithError: URLError(.notConnectedToInternet))
  }
  override class func canInit(with request: URLRequest) -> Bool {
    ["held-sync.invalid", "held-service.invalid"].contains(request.url?.host ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    if request.url?.path == "/v1/session" {
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"name":"Fixture","scopes":["full"]}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } else {
      Self.lock.withLock { Self.pending[request.url!.host!] = self }
    }
  }
  override func stopLoading() {}
}
