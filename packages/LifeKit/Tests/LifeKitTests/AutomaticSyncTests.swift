import Foundation
import Observation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct AutomaticSyncTests {
  @Test func pendingEditsCoalesceAndCatchUpAgainAfterAnEditDuringHeldSync() async throws {
    try await withFixture { model, loops in
      // Queue pending edits before entering the foreground. Saving a real row
      // must not race a 40 ms timer on a busy runner.
      try await save(model, title: "First edit")
      try await save(model, title: "Second edit")
      let started = AutoSyncHub.holdNextPush()
      let loop = Task { await model.runAutomaticSync(debounce: .milliseconds(40)) }
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

  @Test func foregroundExitStopsDebounceAndReentrySendsPendingEdits() async throws {
    try await withFixture { model, loops in
      let loop = Task { await model.runAutomaticSync(debounce: .milliseconds(200)) }
      loops.append(loop)
      await Task.yield()
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
      let resumed = Task { await model.runAutomaticSync(debounce: .milliseconds(20)) }
      loops.append(resumed)
      try await waitUntil(model) { AutoSyncHub.rounds >= 1 && !model.syncing }
      #expect(AutoSyncHub.rounds == 1)
      #expect(AutoSyncHub.uploadedTitles == ["Saved before leaving"])
      #expect(try await model.client?.status().pendingUiEdits == 0)
    }
  }

  @Test func periodicCatchUpBacksOffAfterCancellationAndStopsWhenClosed() async throws {
    try await withFixture { model, loops in
      let started = AutoSyncHub.holdNextSchema()
      let loop = Task {
        await model.runAutomaticSync(interval: .milliseconds(30), debounce: .milliseconds(20))
      }
      loops.append(loop)
      try #require(await started.wait(), "Sync must reach the held schema request")
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
      let started = AutoSyncHub.holdNextSchema()
      let old = Task { await model.runAutomaticSync(interval: .milliseconds(30)) }
      loops.append(old)
      try #require(await started.wait(), "Sync must reach the held schema request")
      old.cancel()
      // Keep periodic catch-up outside the watchdog so it cannot hide a lost edit trigger.
      let current = Task {
        await model.runAutomaticSync(debounce: .milliseconds(20))
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
      let current = Task { await model.runAutomaticSync(debounce: .milliseconds(20)) }
      loops.append(current)
      await Task.yield()
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
        let started = AutoSyncHub.holdNextSchema()
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

  private func save(_ model: WorkspaceModel, title: String) async throws {
    let row = try #require(model.rows.first?.record)
    _ = try await model.save(
      ["id": row["id"]!, "title": .string(title)], original: row, context: model.editingContext)
  }

  private func withFixture(
    _ body: (WorkspaceModel, inout [Task<Void, Never>]) async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let (model, directory) = try await fixture()
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
    do {
      try await model.connect(
        HubCredentials(endpoint: hub.endpoint, token: "fixture"), remember: false,
        synchronizeAfter: false)
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
    }
  }
  static func holdNextSchema() -> AutoSyncSignal { holdNext("/v1/schema/pull") }
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
