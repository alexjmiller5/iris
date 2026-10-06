import Foundation
import Testing

@testable import LifeKit

@MainActor
struct NativeWorkspaceDiagnosticsTests {
  // Removing a phase transition or charging suspended time to active work fails this test.
  @Test func separatesQueueExecutionAndTransportAcrossResumption() throws {
    var time = 0.0
    let diagnostics = NativeWorkspaceDiagnostics(now: { time })
    let id = diagnostics.enqueue(method: .rows)
    time = 0.010
    diagnostics.admit(id)
    time = 0.030
    diagnostics.suspend(id)
    time = 0.080
    diagnostics.resume(id)
    time = 0.095
    diagnostics.admit(id)
    time = 0.100
    diagnostics.finish(id)
    let row = try #require(diagnostics.snapshot().completed.first)
    #expect(abs(row.queuedMilliseconds - 25) < 0.001)
    #expect(abs(row.activeMilliseconds - 25) < 0.001)
    #expect(abs(row.suspendedMilliseconds - 50) < 0.001)
    #expect(abs(row.coreRequestMilliseconds - 100) < 0.001)
    #expect(diagnostics.snapshot().inFlight.isEmpty)
  }

  // Snapshot must include elapsed time without mutating or finishing live requests.
  @Test func snapshotsLivePhasesAndPassivePressure() throws {
    var time = 0.0
    let diagnostics = NativeWorkspaceDiagnostics(now: { time })
    let active = diagnostics.enqueue(method: .catalog)
    diagnostics.admit(active)
    let suspended = diagnostics.enqueue(method: .serviceNotifications, isForeground: false)
    diagnostics.admit(suspended)
    diagnostics.suspend(suspended)
    _ = diagnostics.enqueue(method: .rows)
    diagnostics.setPassiveGateWaiterCount(300)
    time = 0.125
    let first = diagnostics.snapshot()
    #expect(first.activeCount == 1)
    #expect(first.queuedCount == 1)
    #expect(first.suspendedCount == 1)
    #expect(first.passiveGateWaiterCount == 300)
    #expect(first.inFlight.allSatisfy { abs($0.coreRequestMilliseconds - 125) < 0.001 })
    time = 0.250
    #expect(
      diagnostics.snapshot().inFlight.allSatisfy { abs($0.coreRequestMilliseconds - 250) < 0.001 })
    diagnostics.finish(suspended)
    #expect(diagnostics.snapshot().completed.isEmpty)
    diagnostics.setPassiveGateWaiterCount(-1)
    #expect(diagnostics.snapshot().passiveGateWaiterCount == 0)
  }

  // Unbounded history, passive retention, and dropped tracking hidden as completeness are bugs.
  @Test func boundsTrackingAndRetainsOnlyLatestForegroundCompletions() throws {
    let diagnostics = NativeWorkspaceDiagnostics(completedLimit: 2, inFlightLimit: 2)
    let first = diagnostics.enqueue(method: .rows)
    let second = diagnostics.enqueue(method: .catalog)
    #expect(diagnostics.enqueue(method: .search) == nil)
    diagnostics.finish(first)
    diagnostics.finish(second)
    let passive = diagnostics.enqueue(method: .rows, isForeground: false)
    diagnostics.finish(passive)
    let last = diagnostics.enqueue(method: .write)
    diagnostics.finish(last)
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.completed.map(\.id) == [second, last].compactMap { $0 })
    #expect(snapshot.droppedRequestCount == 1)
    #expect(snapshot.inFlight.isEmpty)
    #expect(first != second && second != last)
  }

  // Duplicate/stale hooks cannot resurrect requests or double-charge elapsed time.
  @Test func ignoresInvalidTransitionsAndDuplicateFinish() throws {
    var time = 0.0
    let diagnostics = NativeWorkspaceDiagnostics(now: { time })
    let id = diagnostics.enqueue(method: .catalog)
    diagnostics.suspend(id)
    time = 0.010
    diagnostics.admit(id)
    time = 0.020
    diagnostics.admit(id)
    time = 0.030
    diagnostics.finish(id)
    diagnostics.finish(id)
    diagnostics.resume(id)
    diagnostics.admit(nil)
    let row = try #require(diagnostics.snapshot().completed.first)
    #expect(diagnostics.snapshot().completed.count == 1)
    #expect(abs(row.queuedMilliseconds - 10) < 0.001)
    #expect(abs(row.activeMilliseconds - 20) < 0.001)
  }

  // Post-return DTO decoding must still attach to the retained receipt, without raw observations.
  @Test func aggregatesMetricsBeforeAndAfterCompletion() throws {
    let diagnostics = NativeWorkspaceDiagnostics()
    let id = diagnostics.enqueue(method: .rows)
    diagnostics.addMetrics(.init(sqlMilliseconds: 4, sqlCount: 2, responseBytes: 120), to: id)
    diagnostics.finish(id)
    diagnostics.addMetrics(
      .init(decodeMilliseconds: 3, yieldGapMilliseconds: 5, responseBytes: 80), to: id)
    diagnostics.addMetrics(.init(sqlMilliseconds: 2, sqlCount: 1, yieldGapMilliseconds: 1), to: id)
    diagnostics.addMetrics(
      .init(sqlMilliseconds: -.infinity, sqlCount: -2, responseBytes: -9), to: id)
    let metrics = try #require(diagnostics.snapshot().completed.first).metrics
    #expect(metrics.sqlMilliseconds == 6)
    #expect(metrics.sqlCount == 3)
    #expect(metrics.maximumSQLMilliseconds == 4)
    #expect(metrics.maximumYieldGapMilliseconds == 5)
    #expect(metrics.decodeMilliseconds == 3)
    #expect(metrics.yieldGapMilliseconds == 6)
    #expect(metrics.responseBytes == 200)
    _ = try diagnostics.snapshotJSON(version: "1.2.3", build: "4")
  }

  // A raw method fallback or arbitrary payload field would leak caller-controlled data.
  @Test func exportsOnlyWhitelistedFieldsAndMethodLabels() throws {
    #expect(NativeWorkspaceDiagnostics.Method(rawValue: "SELECT private_value") == nil)
    #expect(NativeWorkspaceDiagnostics.Method(rawValue: "https://private.invalid") == nil)
    let diagnostics = NativeWorkspaceDiagnostics()
    let id = diagnostics.enqueue(method: .serviceUsage)
    diagnostics.finish(id)
    let json = try diagnostics.snapshotJSON(version: "1.2.3", build: "4")
    let document = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(Set(document.keys) == ["schemaVersion", "version", "build", "snapshot"])
    let snapshot = try #require(document["snapshot"] as? [String: Any])
    #expect(
      Set(snapshot.keys) == [
        "completed", "inFlight", "activeCount", "queuedCount", "suspendedCount",
        "passiveGateWaiterCount", "droppedRequestCount",
      ])
    let completed = try #require(snapshot["completed"] as? [[String: Any]])
    let row = try #require(completed.first)
    #expect(
      Set(row.keys) == [
        "id", "method", "isForeground", "phase", "queuedMilliseconds", "activeMilliseconds",
        "suspendedMilliseconds", "coreRequestMilliseconds", "metrics",
      ])
    #expect(row["method"] as? String == "serviceUsage")
    let metrics = try #require(row["metrics"] as? [String: Any])
    #expect(
      Set(metrics.keys) == [
        "sqlMilliseconds", "sqlCount", "decodeMilliseconds", "yieldGapMilliseconds",
        "responseBytes", "maximumSQLMilliseconds", "maximumYieldGapMilliseconds",
      ])
  }

  @Test func rejectsArbitraryMetadataAndSaturatesMetrics() throws {
    let diagnostics = NativeWorkspaceDiagnostics()
    let id = diagnostics.enqueue(method: .rows)
    diagnostics.addMetrics(
      .init(sqlMilliseconds: .greatestFiniteMagnitude, sqlCount: .max, responseBytes: .max), to: id)
    diagnostics.addMetrics(
      .init(
        sqlMilliseconds: .greatestFiniteMagnitude, sqlCount: 1, decodeMilliseconds: .nan,
        responseBytes: 1), to: id)
    diagnostics.finish(id)
    let json = try diagnostics.snapshotJSON(
      version: "private-name", build: "https://private.invalid")
    #expect(!json.contains("private"))
    let document = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(document["version"] as? String == "unknown")
    #expect(document["build"] as? String == "unknown")
    let metrics = try #require(diagnostics.snapshot().completed.first).metrics
    #expect(metrics.sqlCount == Int.max)
    #expect(metrics.responseBytes == Int.max)
    #expect(metrics.sqlMilliseconds.isFinite)
    #expect(metrics.decodeMilliseconds == 0)
  }
}
