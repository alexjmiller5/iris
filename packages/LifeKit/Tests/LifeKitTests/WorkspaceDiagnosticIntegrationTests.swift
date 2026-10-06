import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct WorkspaceDiagnosticIntegrationTests {
  @Test func heldHTTPIsSuspendedWhileCatalogCompletes() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiagnosticHTTP.self]
    let transport = try HubTransport(
      endpoint: "https://diagnostic-fixture.invalid", token: "private-fixture-token",
      configuration: configuration)
    let service = Task { try await workspace.usage(using: transport) }
    defer { DiagnosticHTTP.release() }
    try await waitUntil { DiagnosticHTTP.waiting }
    _ = try await workspace.catalog()
    let snapshot = try report(workspace)
    #expect(snapshot["suspendedCount"] as? Int == 1)
    #expect(snapshot["activeCount"] as? Int == 0)
    let inFlight = try #require(snapshot["inFlight"] as? [[String: Any]])
    #expect(inFlight.first?["method"] as? String == "serviceUsage")
    #expect(inFlight.first?["phase"] as? String == "suspended")
    let json = try workspace.diagnosticReport(version: "1.0", build: "1")
    #expect(!json.contains("diagnostic-fixture.invalid") && !json.contains("private-fixture-token"))
    DiagnosticHTTP.release()
    _ = await service.result
    let after = try report(workspace)
    #expect(after["suspendedCount"] as? Int == 0)
    let completed = try #require(after["completed"] as? [[String: Any]])
    let request = try #require(completed.last { $0["method"] as? String == "serviceUsage" })
    #expect((request["suspendedMilliseconds"] as? Double ?? 0) > 0)
    try await workspace.close()
  }
  @Test func catalogReportsRealBridgeWorkWithoutRecordOrSQLData() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    _ = try await workspace.write(
      table: "notes", patch: ["title": .string("private-fixture-marker")])
    _ = try await workspace.catalog()
    let document = try report(workspace)
    let completed = try #require(document["completed"] as? [[String: Any]])
    let catalog = try #require(completed.last { $0["method"] as? String == "catalog" })
    let metrics = try #require(catalog["metrics"] as? [String: Any])
    #expect((metrics["sqlCount"] as? Int ?? 0) > 0)
    #expect((metrics["sqlMilliseconds"] as? Double ?? 0) > 0)
    #expect((metrics["decodeMilliseconds"] as? Double ?? 0) > 0)
    #expect((metrics["responseBytes"] as? Int ?? 0) > 0)
    #expect((metrics["yieldGapMilliseconds"] as? Double ?? 0) > 0)
    let json = try workspace.diagnosticReport(version: "1.0", build: "1")
    for forbidden in [
      "private-fixture-marker", "SELECT", "catalog_properties", "notes", ":memory:",
    ] {
      #expect(!json.contains(forbidden))
    }
    try await workspace.close()
  }

  @Test func snapshotDoesNotQueueBehindHeldDatabaseAndReportsPassivePressure() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      const originalDiagnosticRequest = LifeNative.request;
      globalThis.releaseDiagnosticRead = null;
      LifeNative.request = (id, method, args) => {
        LifeNative.request = originalDiagnosticRequest;
        LifeSql.begin();
        releaseDiagnosticRead = () => {
          LifeSql.commit(); originalDiagnosticRequest(id, method, args);
          releaseDiagnosticRead = null;
        };
      };
      """#)
    let owner = Task { try await workspace.catalog() }
    defer { runtime.context.evaluateScript("releaseDiagnosticRead?.()") }
    try await waitUntil {
      runtime.context.evaluateScript("releaseDiagnosticRead !== null")?.toBool() == true
    }
    var submitted = 0
    let labels = (0..<5).map { _ in
      Task {
        submitted += 1
        return try await workspace.referenceRows(view: CoreView(table: "notes"))
      }
    }
    try await waitUntil { submitted == labels.count }
    let snapshot = try report(workspace)
    #expect(snapshot["activeCount"] as? Int == 1)
    #expect(snapshot["queuedCount"] as? Int == 1)
    #expect(snapshot["passiveGateWaiterCount"] as? Int == 4)
    #expect(runtime.context.evaluateScript("releaseDiagnosticRead !== null")?.toBool() == true)
    labels.forEach { $0.cancel() }
    runtime.context.evaluateScript("releaseDiagnosticRead()")
    _ = try await owner.value
    for label in labels { _ = await label.result }
    #expect(try report(workspace)["passiveGateWaiterCount"] as? Int == 0)
    try await workspace.close()
  }

  private func report(_ workspace: NativeWorkspace) throws -> [String: Any] {
    let json = try workspace.diagnosticReport(version: "1.0", build: "1")
    let document = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return try #require(document["snapshot"] as? [String: Any])
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition())
  }
}

private final class DiagnosticHTTP: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pending: DiagnosticHTTP?
  static var waiting: Bool { lock.withLock { pending != nil } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.lock.withLock { Self.pending = self } }
  override func stopLoading() {
    Self.lock.withLock { if Self.pending === self { Self.pending = nil } }
  }
  static func release() {
    let current = lock.withLock {
      let value = pending
      pending = nil
      return value
    }
    if let current {
      current.client?.urlProtocol(current, didFailWithError: URLError(.notConnectedToInternet))
    }
  }
}
