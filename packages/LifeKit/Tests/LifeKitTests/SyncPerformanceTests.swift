import Foundation
import Testing

@testable import LifeKit

/// Opt-in measurements of the real SQLite/JSC path. No personal workspace or network.
@Suite(.serialized) @MainActor
struct SyncPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_SYNC_PERFORMANCE"] == "1"))
  func largeCandidateSnapshotKeepsTheMainActorResponsive() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      const ddl = "CREATE TABLE provenance (id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, tbl TEXT, row_id TEXT, col TEXT, source TEXT)";
      LifeSql.run(ddl);
      LifeSql.run("INSERT INTO _schema_log(ddl) VALUES (?)", [ddl]);
      LifeSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('provenance','system','source')");
      LifeSql.run("INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('provenance.source','provenance','source','Source',0,'text')");
      LifeSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50000) INSERT INTO provenance(id,created_at,updated_at,tbl,row_id,col,source) SELECT 'trace-'||i,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z','notes','synthetic-'||i,'title','Synthetic source '||i FROM n");
      """#)
    try #require(runtime.context.exception == nil)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PerformanceHub.self]
    let hub = try HubTransport(
      endpoint: "https://performance.invalid", token: "fixture", configuration: configuration)
    let clock = ContinuousClock()
    var gaps: [Duration] = []
    var last = clock.now
    let heartbeat = Task { @MainActor in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
        let next = clock.now
        gaps.append(last.duration(to: next))
        last = next
      }
    }
    defer { heartbeat.cancel() }
    let started = clock.now
    let first = try await workspace.sync(using: hub)
    let initialDuration = started.duration(to: clock.now)
    #expect(first.pushed >= 50_000)
    let worstGap = gaps.max() ?? .zero
    print(
      "syncBenchmark phase=initial rows=50000 elapsed_ms=\(milliseconds(initialDuration)) max_main_actor_gap_ms=\(milliseconds(worstGap))"
    )
    gaps.removeAll()
    last = clock.now
    let incrementalStart = clock.now
    _ = try await workspace.sync(using: hub)
    print(
      "syncBenchmark phase=incremental rows=50000 elapsed_ms=\(milliseconds(incrementalStart.duration(to: clock.now))) max_main_actor_gap_ms=\(milliseconds(gaps.max() ?? .zero))"
    )

    PerformanceHub.holdNextRequest()
    let heldSync = Task { try await workspace.sync(using: hub, timeout: .seconds(2)) }
    let holdDeadline = clock.now.advanced(by: .seconds(2))
    while !PerformanceHub.isWaiting && clock.now < holdDeadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(PerformanceHub.isWaiting)
    var reads: [Duration] = []
    var saves: [Duration] = []
    for index in 0..<20 {
      let readStart = clock.now
      let rows = try await workspace.rows(table: "provenance")
      #expect(rows.count == 100)
      let note = try #require(try await workspace.rows(table: "notes").first)
      reads.append(readStart.duration(to: clock.now))
      let saveStart = clock.now
      _ = try await workspace.write(
        table: "notes", patch: ["id": .string(note.id), "title": .string("Measurement \(index)")],
        expectedUpdatedAt: note.record["updated_at"]?.text)
      saves.append(saveStart.duration(to: clock.now))
    }
    #expect(PerformanceHub.isWaiting, "Measurements must finish while network remains held")
    PerformanceHub.release()
    _ = await heldSync.result
    print(
      "syncBenchmark phase=held_network samples=20 read_p95_ms=\(milliseconds(reads.sorted()[18])) read_max_ms=\(milliseconds(reads.max()!)) save_p95_ms=\(milliseconds(saves.sorted()[18]))"
    )
    try await workspace.close()
    #expect(reads.max()! < .milliseconds(150))
    #expect(saves.max()! < .milliseconds(250))
    #expect(
      worstGap < .milliseconds(50), "Large sync candidate reads must not monopolize the main actor")
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }
}

private final class PerformanceHub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var hold = false
  nonisolated(unsafe) private static var pending: PerformanceHub?
  static func holdNextRequest() { lock.withLock { hold = true } }
  static var isWaiting: Bool { lock.withLock { pending != nil } }
  static func release() {
    let held = lock.withLock {
      let held = pending
      pending = nil
      return held
    }
    if let held {
      held.client?.urlProtocol(held, didFailWithError: URLError(.notConnectedToInternet))
    }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "performance.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    Self.lock.withLock { if Self.pending === self { Self.pending = nil } }
  }
  override func startLoading() {
    if Self.lock.withLock({
      guard Self.hold else { return false }
      Self.hold = false
      Self.pending = self
      return true
    }) {
      return
    }
    do {
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
      let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      let data: [String: Any]
      switch request.url!.path {
      case "/v1/schema/pull": data = ["entries": []]
      case "/v1/schema/push": data = [:]
      case "/v1/stats":
        data = [
          "tables": Dictionary(
            uniqueKeysWithValues: [
              "notes", "topics", "catalog_tables", "catalog_properties", "catalog_rules", "history",
              "views", "provenance",
            ].map { ($0, $0 == "provenance" ? 50_000 : 1) })
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
