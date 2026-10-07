import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct ForegroundSyncTests {
  @Test func backgroundGETDoesNotBlockLocalWorkOrBorrowSyncTransport() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let syncHub = try transport()
    let syncStarted = HeldSyncTransport.nextStart()
    let sync = Task { try await workspace.sync(using: syncHub) }
    defer {
      HeldSyncTransport.release(host: "held-service.invalid")
      HeldSyncTransport.release()
    }
    #expect(await syncStarted.wait(), "Sync must reach its held HTTP boundary")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldSyncTransport.self]
    let serviceHub = try HubTransport(
      endpoint: "https://held-service.invalid", token: "service-fixture",
      configuration: configuration)
    let serviceStarted = HeldSyncTransport.nextStart(host: "held-service.invalid")
    let service = Task { try await workspace.notifications(using: serviceHub) }
    #expect(await serviceStarted.wait(), "Notifications must reach the separate held GET")
    let readFinished = TestSignal()
    let read = Task {
      defer { readFinished.signal() }
      let rows = try await workspace.rows(table: "notes")
      #expect(!rows.isEmpty)
    }
    #expect(
      await readFinished.wait(), "Local read must complete before either HTTP request is released")
    #expect(HeldSyncTransport.isWaiting, "Sync transport must still be held after local completion")
    #expect(
      HeldSyncTransport.isWaiting(host: "held-service.invalid"),
      "GET transport must still be held after local completion")
    HeldSyncTransport.release(host: "held-service.invalid")
    _ = await service.result
    #expect(HeldSyncTransport.isWaiting)
    HeldSyncTransport.release()
    _ = await sync.result
    try await read.value
    try await workspace.close()
  }
  @Test func anotherWindowReadsAndSavesWhileTheSameFileSyncWaitsForHTTP() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite").path
    let first = try NativeWorkspace(path: path)
    try await first.createSample()
    let second = try NativeWorkspace(path: path)
    let started = HeldSyncTransport.nextStart()
    let hub = try transport()
    let sync = Task { try await first.sync(using: hub) }
    defer { HeldSyncTransport.release() }
    #expect(await started.wait())
    let completed = TestSignal()
    let local = Task {
      defer { completed.signal() }
      let row = try #require(try await second.rows(table: "notes").first)
      _ = try await second.write(
        table: "notes",
        patch: [
          "id": .string(row.id), "title": .string("Saved while another window syncs"),
        ])
      #expect(
        try await second.rows(table: "notes").contains {
          $0.id == row.id && $0.label == "Saved while another window syncs"
        })
    }
    #expect(
      await completed.wait(), "A different window must complete local work before HTTP release")
    #expect(HeldSyncTransport.isWaiting)
    HeldSyncTransport.release()
    _ = await sync.result
    try await local.value
    try await first.close()
    try await second.close()
  }

  @Test(arguments: ["http", "yield"])
  func callbackFailureRollsBackAndReleasesOtherWindows(boundary: String) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite").path
    let runtime = try LifeCoreRuntime()
    let first = try NativeWorkspace(path: path, runtime: runtime)
    try await first.createSample()
    let second = try NativeWorkspace(path: path)
    let registration =
      boundary == "http" ? "__lifePost('/schema/pull', '{}', callback)" : "__lifeYield(callback)"
    runtime.context.evaluateScript(
      """
      LifeNative.request = function(id, method, args) {
        globalThis.callbackRequestID = id;
        const callback = () => {
          LifeSql.begin();
          LifeSql.run("UPDATE notes SET title='Uncommitted callback'");
          throw new Error('Synthetic callback failure');
        };
        \(registration);
      };
      """)
    let completed = TestSignal()
    let hub = try transport()
    let started = boundary == "http" ? HeldSyncTransport.nextStart() : nil
    let request = Task {
      defer { completed.signal() }
      if boundary == "http" {
        _ = try await first.sync(using: hub)
      } else {
        _ = try await first.catalog()
      }
    }
    if let started {
      #expect(await started.wait())
      HeldSyncTransport.release()
    }
    let finished = await completed.wait()
    #expect(finished, "A synchronous callback failure must reject its request")
    if !finished {
      runtime.context.exception = nil
      runtime.context.evaluateScript(
        #"try { LifeSql.rollback(); } catch {} __lifeFinish(callbackRequestID, '{"error":"Test cleanup"}');"#
      )
    }
    await #expect(throws: Error.self) { try await request.value }
    let rows = try await second.rows(table: "notes")
    #expect(!rows.isEmpty && rows.allSatisfy { $0.label != "Uncommitted callback" })
    try await first.close()
    try await second.close()
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
  @Test func closingWorkspaceCancelsHeldSyncAndRetainsQueuedLocalEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hub = try transport()
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub })
    try await model.connect(
      HubCredentials(endpoint: hub.endpoint, token: "fixture"), remember: false,
      synchronizeAfter: false)
    let workspace = try #require(model.client)
    try await workspace.createSample()
    let row = try #require(try await workspace.rows(table: "notes").first)
    _ = try await workspace.write(
      table: "notes", patch: ["id": .string(row.id), "title": .string("Queued offline edit")])
    let before = try await workspace.rows(table: "notes")
    let status = try await workspace.status()
    #expect(status.pendingUiEdits > 0)
    let sync = Task { await model.synchronize() }
    try await waitUntil { HeldSyncTransport.isWaiting }
    let completed = TestSignal()
    let close = Task {
      await model.close()
      completed.signal()
    }
    let closed = await completed.wait()
    #expect(closed, "Close workspace must not await a stalled hub response")
    // Unblock the unfixed implementation after the bounded failure.
    HeldSyncTransport.release()
    await close.value
    await sync.value
    #expect(model.client == nil && model.catalog == nil && model.rows.isEmpty)
    #expect(!model.syncing && model.syncProgress == nil)
    #expect(model.error == nil)
    let reopened = try NativeWorkspace(
      path: WorkspaceModel.replicaURL(
        root: directory, endpoint: hub.endpoint
      ).path)
    #expect(try await reopened.rows(table: "notes") == before)
    #expect(try await reopened.status().pendingUiEdits == status.pendingUiEdits)
    try await reopened.close()
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
  private func waitUntil(
    _ condition: () -> Bool, file: StaticString = #fileID, line: UInt = #line
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(20))
    while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), Comment(rawValue: "Barrier watchdog expired at \(file):\(line)"))
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
    let requestsBefore = HeldSyncTransport.startCount
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
    #expect(
      HeldSyncTransport.startCount == requestsBefore,
      "No HTTP may start inside an owned transaction")
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
    try await waitUntil { HeldSyncTransport.isWaiting }
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
    try await waitUntil { finished }
    #expect(
      finished, "Local catalog, rows and save must finish before the HTTP response is released")
    #expect(HeldSyncTransport.isWaiting)
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

/// Ordering proof, not a latency benchmark: the full suite shares MainActor.
/// Keep a watchdog below the transport timeout so a missing yield still fails
/// before URLSession can accidentally unblock the local operation for us.
private struct TestSignal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() {
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }
  func signal() {
    continuation.yield(())
    continuation.finish()
  }
  func wait() async -> Bool {
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = stream.makeAsyncIterator()
    return await iterator.next() != nil
  }
}

private final class HeldSyncTransport: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pending: [String: HeldSyncTransport] = [:]
  nonisolated(unsafe) private static var starts: [String: TestSignal] = [:]
  nonisolated(unsafe) private static var started = 0
  static var startCount: Int { lock.withLock { started } }
  static func nextStart(host: String = "held-sync.invalid") -> TestSignal {
    lock.withLock {
      let signal = TestSignal()
      starts[host] = signal
      return signal
    }
  }
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
      let signal = Self.lock.withLock {
        let host = request.url!.host!
        Self.started += 1
        Self.pending[host] = self
        return Self.starts.removeValue(forKey: host)
      }
      signal?.signal()
    }
  }
  override func stopLoading() {
    Self.lock.withLock {
      let host = request.url!.host!
      if Self.pending[host] === self { Self.pending.removeValue(forKey: host) }
    }
  }
}
