import Foundation
import JavaScriptCore
import Observation
import Testing

@testable import IrisKit

@Suite(.serialized) @MainActor
struct AutomaticSyncTests {
  @Test func pendingEditsCoalesceAndCatchUpAgainAfterAnEditDuringHeldSync() async throws {
    try await withFixture { model, loops in
      // Queue pending edits before entering the foreground. Saving a real row
      // must not race a 40 ms timer on a busy runner.
      try await save(model, title: "First edit")
      try await save(model, title: "Second edit")
      let started = AutoSyncHub.holdNextPush()
      let loop = Task {
        await model.runAutomaticSync(interval: .seconds(60), debounce: .milliseconds(40))
      }
      loops.append(loop)
      try #require(await started.wait(), "Sync must reach the held push")
      #expect(AutoSyncHub.rounds == 1)
      try await save(model, title: "Edit while uploading")
      #expect(AutoSyncHub.waiting)
      AutoSyncHub.release()
      try await waitUntil(model) { AutoSyncHub.rounds >= 2 && !model.syncing }
      #expect(AutoSyncHub.rounds == 2)
      #expect(model.rows.first?.record["title"] == .string("Edit while uploading"))
      #expect(AutoSyncHub.uploadedTitles == ["Second edit", "Edit while uploading"])
      #expect(try await model.client?.status().pendingUiEdits == 0)
    }
  }

  @Test func committedViewUndoStillUploadsWhenRefreshingViewsFails() async throws {
    let runtime = try IrisCoreRuntime()
    try await withFixture(runtime: runtime) { model, loops in
      let context = try #require(model.editingContext)
      try await model.saveCurrentView(name: "Undo sync fixture", update: false, context: context)
      await model.synchronize()
      try #require(model.error == nil)
      let action = try #require(model.undoAction)
      try #require(action.table == "views")
      try await startForegroundLoop(model, &loops, debounce: .milliseconds(20))
      let started = AutoSyncHub.holdNextPush()
      runtime.context.evaluateScript(
        """
        const beforeRefreshFailure = IrisNative.request;
        IrisNative.request = (id, method, args) => {
          if (method === 'listViews') {
            IrisNative.request = beforeRefreshFailure;
            __irisFinish(id, JSON.stringify({error:'Synthetic view refresh failure',violations:[]}));
          } else beforeRefreshFailure(id, method, args);
        };
        """)
      try #require(runtime.context.exception == nil)
      do {
        _ = try await model.undo(action, context: context)
        Issue.record("The post-commit view refresh must fail")
      } catch {
        #expect(error.localizedDescription.contains("Synthetic view refresh failure"))
      }
      #expect(try await model.client?.status().pendingUiEdits == 1)
      try #require(await started.wait(), "Committed Undo must upload despite view refresh failure")
      AutoSyncHub.release()
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(AutoSyncHub.rounds == 1)
      #expect(try await model.client?.status().pendingUiEdits == 0)
    }
  }

  @Test func foregroundExitStopsDebounceAndReentrySendsPendingEdits() async throws {
    try await withFixture { model, loops in
      let loop = try await startForegroundLoop(model, &loops, debounce: .milliseconds(200))
      // Saving schedules catch-up before awaiting reload. Leave at that boundary,
      // rather than assuming reload finishes within the debounce on a busy runner.
      _ = withObservationTracking {
        model.loading
      } onChange: {
        loop.cancel()
      }
      try await save(model, title: "Saved before leaving")
      #expect(loop.isCancelled, "Foreground exit must happen when the saved row starts reloading")
      loop.cancel()
      await loop.value
      try await Task.sleep(for: .milliseconds(250))
      #expect(AutoSyncHub.rounds == 0)
      #expect(try await model.client?.status().pendingUiEdits == 1)
      // Returning to the foreground pulls (and uploads) immediately.
      let resumed = Task {
        await model.runAutomaticSync(interval: .seconds(60), debounce: .seconds(30))
      }
      loops.append(resumed)
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(AutoSyncHub.rounds == 1)
      #expect(AutoSyncHub.uploadedTitles == ["Saved before leaving"])
      #expect(try await model.client?.status().pendingUiEdits == 0)
    }
  }

  @Test func periodicCatchUpBacksOffAfterCancellationAndStopsWhenClosed() async throws {
    try await withFixture { model, loops in
      let started = AutoSyncHub.holdNextRound()
      let loop = Task {
        await model.runAutomaticSync(interval: .milliseconds(30), debounce: .milliseconds(20))
      }
      loops.append(loop)
      try #require(await started.wait(), "Sync must reach the held cursor request")
      try await save(model, title: "Still local")
      model.cancelSync()
      try await waitUntil(model) { !model.syncing }
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
  }

  @Test func reentryDuringAnActivePeriodicRoundKeepsTheNewForegroundLoop() async throws {
    try await withFixture { model, loops in
      let started = AutoSyncHub.holdNextRound()
      let old = Task { await model.runAutomaticSync(interval: .milliseconds(30)) }
      loops.append(old)
      try #require(await started.wait(), "Sync must reach the held cursor request")
      old.cancel()
      // Keep periodic catch-up outside the watchdog so it cannot hide a lost edit trigger.
      let current = Task {
        await model.runAutomaticSync(interval: .seconds(60), debounce: .milliseconds(20))
      }
      loops.append(current)
      await Task.yield()
      AutoSyncHub.release()
      await old.value
      try await Task.sleep(for: .milliseconds(80))
      #expect(AutoSyncHub.rounds == 1)
      try await save(model, title: "Saved after returning")
      try await waitUntil(model) { AutoSyncHub.rounds >= 2 && !model.syncing }
      #expect(AutoSyncHub.rounds == 2)
      #expect(AutoSyncHub.uploadedTitles.last == "Saved after returning")
    }
  }

  @Test func aCancelledSceneTaskCannotReplaceTheCurrentForegroundLoop() async throws {
    try await withFixture { model, loops in
      let release = AutoSyncSignal()
      // The gate outlives cancellation of the old scene task so it can attempt
      // reentry after the current scene starts. Always release it on failure.
      let gate = Task { await release.wait() }
      defer {
        release.signal()
        gate.cancel()
      }
      let old = Task {
        _ = await gate.value
        await model.runAutomaticSync()
      }
      loops.append(old)
      old.cancel()
      try await startForegroundLoop(model, &loops, debounce: .milliseconds(20))
      release.signal()
      await old.value
      try await save(model, title: "Current foreground edit")
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(AutoSyncHub.rounds == 1)
      #expect(AutoSyncHub.uploadedTitles.last == "Current foreground edit")
    }
  }

  @Test(arguments: [false, true])
  func failureAndCancellationReleaseHeldTransport(cancelled: Bool) async throws {
    enum FixtureFailure: Error { case expected }
    var modelAfterFailure: WorkspaceModel?
    var loopAfterFailure: Task<Void, Never>?
    let operation = Task { @MainActor in
      try await withFixture { model, loops in
        modelAfterFailure = model
        let started = AutoSyncHub.holdNextRound()
        let loop = Task { await model.runAutomaticSync(interval: .milliseconds(20)) }
        loops.append(loop)
        loopAfterFailure = loop
        try #require(await started.wait(), "Cleanup regression must hold a real request")
        if cancelled {
          withUnsafeCurrentTask { $0?.cancel() }
          try Task.checkCancellation()
        }
        throw FixtureFailure.expected
      }
    }
    do {
      try await operation.value
      Issue.record("The fixture body must fail")
    } catch {
      #expect(cancelled ? error is CancellationError : error is FixtureFailure)
    }
    #expect(modelAfterFailure != nil)
    #expect(modelAfterFailure?.client == nil)
    #expect(loopAfterFailure?.isCancelled == true)
    #expect(!AutoSyncHub.waiting)
  }

  @Test func activationPullsImmediatelyThenCatchesUpEveryTwoSeconds() async throws {
    try await withFixture { model, loops in
      let started = ContinuousClock.now
      loops.append(Task { await model.runAutomaticSync() })
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(started.duration(to: .now) < .seconds(1.5), "Activation must not wait an interval")
      let first = ContinuousClock.now
      try await waitUntil(model) { AutoSyncHub.rounds >= 2 }
      let gap = first.duration(to: .now)
      #expect(gap >= .seconds(1.9) && gap < .seconds(6), "Catch-up cadence was \(gap)")
    }
  }

  @Test func offlinePausesSyncAndReconnectingUploadsImmediately() async throws {
    try await withFixture { model, loops in
      model.setOnline(false)
      loops.append(
        Task {
          await model.runAutomaticSync(interval: .milliseconds(30), debounce: .milliseconds(20))
        })
      try await save(model, title: "Written offline")
      try await Task.sleep(for: .milliseconds(200))
      #expect(AutoSyncHub.rounds == 0, "Offline must pause both periodic and edit catch-up")
      #expect(model.syncPill.title == "Offline · 1 pending")
      model.setOnline(true)
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(AutoSyncHub.uploadedTitles == ["Written offline"])
      #expect(model.syncPill.title == "Synced")
    }
  }

  @Test func failedRoundsSurfaceOnlyThroughThePill() async throws {
    try await withFixture { model, _ in
      try await save(model, title: "Kept locally")
      AutoSyncHub.fail(0)
      await model.synchronize()
      #expect(model.syncPill.title == "Offline · 1 pending")
      #expect(model.error == nil, "Connectivity is shown by the pill, not a record notice")
      AutoSyncHub.fail(429)
      await model.synchronize()
      #expect(model.syncPill.title == "Paused: cap reached")
      AutoSyncHub.fail(nil)
      await model.synchronize()
      #expect(model.syncError == nil)
      #expect(model.syncPill.title == "Synced")
      #expect(AutoSyncHub.uploadedTitles == ["Kept locally"])
    }
  }

  @Test func aLiveSocketReplacesTheShortCheckAndEachChangeRunsARound() async throws {
    let hub = FakeWakeHub()
    try await withFixture(signal: hub.signal()) { model, loops in
      loops.append(
        Task {
          await model.runAutomaticSync(
            interval: .milliseconds(200), liveInterval: .seconds(60), debounce: .milliseconds(20))
        })
      try await waitUntil(model) { model.liveness == .live && AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(model.syncPill.title == "Live")
      try await Task.sleep(for: .milliseconds(300))  // the socket-open round settles
      let settled = AutoSyncHub.rounds
      try await Task.sleep(for: .seconds(1))
      #expect(AutoSyncHub.rounds == settled, "A live socket must stop the 200 ms check")
      hub.connections[0].deliver(#"{"seq":2,"tables":["notes"]}"#)
      try await waitUntil(model) { AutoSyncHub.rounds == settled + 1 && !model.syncing }
      // Down: the short check resumes and the pill says so.
      hub.refusing = true
      hub.connections[0].drop()
      try await waitUntil(model) { model.liveness == .reconnecting }
      #expect(model.syncPill.title == "Reconnecting")
      let dropped = AutoSyncHub.rounds
      try await Task.sleep(for: .seconds(1))
      #expect(AutoSyncHub.rounds >= dropped + 3, "Rounds while down: \(AutoSyncHub.rounds - dropped)")
    }
  }

  @Test func aChangeDuringARoundRunsOneMoreAfterIt() async throws {
    let hub = FakeWakeHub()
    try await withFixture(signal: hub.signal()) { model, loops in
      loops.append(
        Task {
          await model.runAutomaticSync(
            interval: .seconds(60), liveInterval: .seconds(60), debounce: .milliseconds(20))
        })
      try await waitUntil(model) { model.liveness == .live && AutoSyncHub.rounds >= 1 && !model.syncing }
      try await Task.sleep(for: .milliseconds(300))
      let before = AutoSyncHub.rounds
      let held = AutoSyncHub.holdNextRound()
      hub.connections[0].deliver(#"{"seq":2,"tables":["notes"]}"#)
      try #require(await held.wait(), "The change must start a round")
      hub.connections[0].deliver(#"{"seq":3,"tables":["notes"]}"#)
      try await Task.sleep(for: .milliseconds(100))
      AutoSyncHub.release()
      try await waitUntil(model) { AutoSyncHub.rounds == before + 2 && !model.syncing }
      try await Task.sleep(for: .milliseconds(300))
      #expect(AutoSyncHub.rounds == before + 2)
    }
  }

  @Test func aSilentPushRunsOneRoundUnlessTheSocketIsLive() async throws {
    let hub = FakeWakeHub()
    try await withFixture(signal: hub.signal()) { model, loops in
      // Backgrounded: no foreground loop, so the push is the only trigger.
      #expect(await model.pushWake() == false)  // nothing moved
      #expect(AutoSyncHub.rounds == 1)
      try await save(model, title: "Written before the push")
      _ = await model.pushWake()
      #expect(AutoSyncHub.uploadedTitles == ["Written before the push"])
      loops.append(Task { await model.runAutomaticSync(interval: .seconds(60), debounce: .milliseconds(20)) })
      try await waitUntil(model) { model.liveness == .live && !model.syncing }
      try await Task.sleep(for: .milliseconds(300))
      let live = AutoSyncHub.rounds
      #expect(await model.pushWake() == false)
      #expect(AutoSyncHub.rounds == live, "The live socket already covers the push")
    }
  }

  @Test func quietRoundsLeaveLoadedRowsAlone() async throws {
    try await withFixture { model, _ in
      let revision = model.syncDataRevision
      await model.synchronize()
      #expect(model.syncDataRevision == revision, "A round that moved nothing must not reload")
      try await save(model, title: "Moved")
      await model.synchronize()
      #expect(model.syncDataRevision == revision + 1)
    }
  }

  /// Starts the foreground loop, lets its activation round finish, then resets counters.
  @discardableResult
  private func startForegroundLoop(
    _ model: WorkspaceModel, _ loops: inout [Task<Void, Never>], debounce: Duration
  ) async throws -> Task<Void, Never> {
    let loop = Task { await model.runAutomaticSync(interval: .seconds(60), debounce: debounce) }
    loops.append(loop)
    try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
    AutoSyncHub.reset()
    return loop
  }

  private func save(_ model: WorkspaceModel, title: String) async throws {
    let row = try #require(model.rows.first?.record)
    _ = try await model.save(
      ["id": row["id"]!, "title": .string(title)], original: row, context: model.editingContext)
  }

  private func withFixture(
    runtime: IrisCoreRuntime? = nil, signal: HubChangeSignal? = nil,
    _ body: (WorkspaceModel, inout [Task<Void, Never>]) async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let (model, directory) = try await fixture(runtime: runtime, signal: signal)
    var loops: [Task<Void, Never>] = []
    do {
      try await body(model, &loops)
    } catch {
      await cleanUp(model, directory: directory, loops: loops, sourceLocation: sourceLocation)
      throw error
    }
    await cleanUp(model, directory: directory, loops: loops, sourceLocation: sourceLocation)
  }

  private func cleanUp(
    _ model: WorkspaceModel, directory: URL, loops: [Task<Void, Never>],
    sourceLocation: SourceLocation
  ) async {
    // An unstructured task does not inherit the test's cancellation. Bound its
    // wait independently, and never remove a database before close completes.
    let cleanup = Task { @MainActor in
      for loop in loops { loop.cancel() }
      model.cancelSync()
      AutoSyncHub.release()
      let completed = AutoSyncSignal()
      let closing = Task { @MainActor in
        await model.close()
        for loop in loops { await loop.value }
        if model.client == nil {
          do { try FileManager.default.removeItem(at: directory) } catch {
            Issue.record(error, sourceLocation: sourceLocation)
          }
        } else {
          Issue.record(
            "Close failed; fixture retained at \(directory.path): \(String(describing: model.error))",
            sourceLocation: sourceLocation)
        }
        completed.signal()
      }
      let finished = await completed.wait()
      if !finished { closing.cancel() }
      #expect(
        finished, "Automatic sync fixture cleanup exceeded 20 seconds",
        sourceLocation: sourceLocation)
    }
    await cleanup.value
  }

  private func fixture(runtime: IrisCoreRuntime? = nil, signal: HubChangeSignal? = nil) async throws
    -> (WorkspaceModel, URL)
  {
    AutoSyncHub.reset()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AutoSyncHub.self]
    let hub = try HubTransport(
      endpoint: "https://automatic-sync.invalid", token: "fixture", configuration: configuration)
    // No socket unless a test scripts one: the plain 2 s check is the baseline.
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub },
      changeSignal: { _ in signal })
    do {
      try await model.connect(
        HubCredentials(endpoint: hub.endpoint, token: "fixture"), remember: false,
        synchronizeAfter: false)
      if let runtime {
        try await #require(model.client).close()
        model.client = try NativeWorkspace(
          path: directory.appendingPathComponent("local.sqlite").path, runtime: runtime)
      }
      try await #require(model.client).createSample()
      model.catalog = try await #require(model.client).catalog()
      model.table = "notes"
      await model.reload()
      await model.synchronize()
      try #require(model.error == nil)
    } catch {
      await cleanUp(model, directory: directory, loops: [], sourceLocation: #_sourceLocation)
      throw error
    }
    AutoSyncHub.reset()
    return (model, directory)
  }

  private func waitUntil(
    _ model: WorkspaceModel, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
  ) async throws {
    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      continuation.finish()
    }
    defer {
      watchdog.cancel()
      continuation.finish()
    }
    var iterator = changes.makeAsyncIterator()
    while true {
      try Task.checkCancellation()
      let satisfied = withObservationTracking {
        // Always observe syncing, even when the round-count condition short-circuits.
        _ = model.syncing
        return condition()
      } onChange: {
        continuation.yield(())
      }
      if satisfied { return }
      if await iterator.next() == nil {
        try Task.checkCancellation()
        try #require(
          condition(),
          "Sync state watchdog expired: rounds=\(AutoSyncHub.rounds), syncing=\(model.syncing), error=\(String(describing: model.error))",
          sourceLocation: sourceLocation)
        return
      }
    }
  }
}

private struct AutoSyncSignal: Sendable {
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

private final class AutoSyncHub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var count = 0
  nonisolated(unsafe) private static var holdRoute: String?
  nonisolated(unsafe) private static var heldSignal: AutoSyncSignal?
  nonisolated(unsafe) private static var titles: [String] = []
  private var savedBytes: Data?
  nonisolated(unsafe) private static var held: AutoSyncHub?
  /// 0 fails the connection; another value answers every sync route with that status.
  nonisolated(unsafe) private static var failStatus: Int?
  static func fail(_ status: Int?) { lock.withLock { failStatus = status } }
  static var uploadedTitles: [String] { lock.withLock { titles } }
  static var rounds: Int { lock.withLock { count } }
  static var waiting: Bool { lock.withLock { held != nil } }
  static func reset() {
    lock.withLock {
      count = 0
      holdRoute = nil
      heldSignal = nil
      titles = []
      held = nil
      failStatus = nil
    }
  }
  /// Every round, quiet or not, opens with the cursor read.
  static func holdNextRound() -> AutoSyncSignal { holdNext("/v1/cursor") }
  static func holdNextPush() -> AutoSyncSignal { holdNext("/v1/rows/push") }
  private static func holdNext(_ route: String) -> AutoSyncSignal {
    lock.withLock {
      let signal = AutoSyncSignal()
      holdRoute = route
      heldSignal = signal
      return signal
    }
  }
  static func release() {
    let pending = lock.withLock {
      holdRoute = nil
      heldSignal = nil
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
    if request.url?.path == "/v1/cursor" { Self.lock.withLock { Self.count += 1 } }
    if let status = Self.lock.withLock({ Self.failStatus }) {
      guard status != 0 else {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        return
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"error":"synthetic failure"}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
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
      if let started = Self.lock.withLock({ () -> AutoSyncSignal? in
        guard Self.holdRoute == request.url?.path else { return nil }
        Self.holdRoute = nil
        Self.held = self
        let signal = Self.heldSignal
        Self.heldSignal = nil
        return signal
      }) {
        started.signal()
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
