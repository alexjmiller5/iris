import Foundation

/// In-memory, explicitly exported timing evidence. Never accepts request payloads or raw labels.
@MainActor
final class NativeWorkspaceDiagnostics {
  typealias RequestID = UInt64

  enum Method: String, Codable {
    case catalog, rows, options, write, status, sync
    case serviceUsage, serviceNotifications, markNotificationsRead, notificationPresentation
    case search, listViews, saveView, deleteView, writeability, remoteRows, remoteRow
    case undoStatus, undo, enrollmentApproval, validateDeviceSession, enrollmentPollResult
    case sessionRevocationResult, referenceSources, referencedBy, rejections, runRowAction
    case resolveSourceLink, sample, prepareLocalViews, prepareLocalPins, close
    case listSidebarPins, pinTable, unpinTable, moveTablePin
    case catalogRevision, mentionLabels, ensureDefaultView, searchIndexStep
  }

  enum Phase: String, Codable { case queued, active, suspended, completed }

  struct Metrics: Encodable {
    var sqlMilliseconds: Double = 0
    var sqlCount: Int = 0
    var decodeMilliseconds: Double = 0
    var yieldGapMilliseconds: Double = 0
    var responseBytes: Int = 0
    var maximumSQLMilliseconds: Double = 0
    var maximumYieldGapMilliseconds: Double = 0

    fileprivate mutating func add(_ other: Metrics) {
      sqlMilliseconds = Self.sum(sqlMilliseconds, other.sqlMilliseconds)
      sqlCount = Self.sum(sqlCount, other.sqlCount)
      decodeMilliseconds = Self.sum(decodeMilliseconds, other.decodeMilliseconds)
      yieldGapMilliseconds = Self.sum(yieldGapMilliseconds, other.yieldGapMilliseconds)
      responseBytes = Self.sum(responseBytes, other.responseBytes)
      maximumSQLMilliseconds = Self.peak(maximumSQLMilliseconds, other.sqlMilliseconds)
      maximumYieldGapMilliseconds = Self.peak(
        maximumYieldGapMilliseconds, other.yieldGapMilliseconds)
    }

    private static func peak(_ lhs: Double, _ rhs: Double) -> Double {
      rhs.isFinite && rhs >= 0 ? max(lhs, rhs) : lhs
    }

    fileprivate static func sum(_ lhs: Double, _ rhs: Double) -> Double {
      guard rhs.isFinite, rhs >= 0 else { return lhs }
      return min(Double.greatestFiniteMagnitude, lhs + rhs)
    }

    fileprivate static func sum(_ lhs: Int, _ rhs: Int) -> Int {
      let (value, overflow) = lhs.addingReportingOverflow(max(0, rhs))
      return overflow ? .max : value
    }
  }

  struct Record: Encodable {
    let id: RequestID
    let method: Method
    let isForeground: Bool
    var phase: Phase = .queued
    var queuedMilliseconds: Double = 0
    var activeMilliseconds: Double = 0
    var suspendedMilliseconds: Double = 0
    // Ends when the native core callback settles; later DTO decoding is separate.
    var coreRequestMilliseconds: Double = 0
    var metrics = Metrics()
  }

  struct Snapshot: Encodable {
    let completed: [Record]
    let inFlight: [Record]
    let activeCount: Int
    let queuedCount: Int
    let suspendedCount: Int
    let passiveGateWaiterCount: Int
    let droppedRequestCount: Int
  }

  private struct Pending {
    var record: Record
    var phaseStarted: TimeInterval

    mutating func accrue(until now: TimeInterval) {
      let elapsed = max(0, now - phaseStarted) * 1_000
      switch record.phase {
      case .queued: record.queuedMilliseconds = Metrics.sum(record.queuedMilliseconds, elapsed)
      case .active: record.activeMilliseconds = Metrics.sum(record.activeMilliseconds, elapsed)
      case .suspended:
        record.suspendedMilliseconds = Metrics.sum(record.suspendedMilliseconds, elapsed)
      case .completed: break
      }
      record.coreRequestMilliseconds = Metrics.sum(record.coreRequestMilliseconds, elapsed)
      phaseStarted = max(phaseStarted, now)
    }
  }

  private let now: () -> TimeInterval
  private let completedLimit: Int
  private let inFlightLimit: Int
  private var nextID: RequestID = 0
  private var pending: [RequestID: Pending] = [:]
  private var completed: [Record] = []
  private var passiveGateWaiterCount = 0
  private var droppedRequestCount = 0

  init(
    completedLimit: Int = 64, inFlightLimit: Int = 512,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.completedLimit = min(64, max(0, completedLimit))
    self.inFlightLimit = min(512, max(0, inFlightLimit))
    self.now = now
  }

  func enqueue(method: Method, isForeground: Bool = true) -> RequestID? {
    guard pending.count < inFlightLimit, nextID < .max else {
      droppedRequestCount = Metrics.sum(droppedRequestCount, 1)
      return nil
    }
    nextID += 1
    pending[nextID] = Pending(
      record: Record(id: nextID, method: method, isForeground: isForeground), phaseStarted: now())
    return nextID
  }

  func admit(_ id: RequestID?) { transition(id, from: .queued, to: .active) }
  func suspend(_ id: RequestID?) { transition(id, from: .active, to: .suspended) }

  /// HTTP has returned; its continuation still waits for database admission.
  func resume(_ id: RequestID?) { transition(id, from: .suspended, to: .queued) }

  func finish(_ id: RequestID?) {
    guard let id, var request = pending.removeValue(forKey: id) else { return }
    request.accrue(until: now())
    request.record.phase = .completed
    guard request.record.isForeground, completedLimit > 0 else { return }
    if completed.count == completedLimit { completed.removeFirst() }
    completed.append(request.record)
  }

  /// Accepts aggregate timings only. DTO decoding can arrive after the core request completes.
  func addMetrics(_ metrics: Metrics, to id: RequestID?) {
    guard let id else { return }
    if pending[id] != nil {
      pending[id]?.record.metrics.add(metrics)
    } else if let index = completed.firstIndex(where: { $0.id == id }) {
      completed[index].metrics.add(metrics)
    }
  }

  func setPassiveGateWaiterCount(_ count: Int) { passiveGateWaiterCount = max(0, count) }

  func snapshot() -> Snapshot {
    let instant = now()
    let inFlight = pending.values.map { pending in
      var copy = pending
      copy.accrue(until: instant)
      return copy.record
    }.sorted { $0.id < $1.id }
    return Snapshot(
      completed: completed, inFlight: inFlight,
      activeCount: inFlight.filter { $0.phase == .active }.count,
      queuedCount: inFlight.filter { $0.phase == .queued }.count,
      suspendedCount: inFlight.filter { $0.phase == .suspended }.count,
      passiveGateWaiterCount: passiveGateWaiterCount, droppedRequestCount: droppedRequestCount)
  }

  func snapshotJSON(version: String, build: String) throws -> String {
    struct Export: Encodable {
      let schemaVersion = 1
      let version: String
      let build: String
      let snapshot: Snapshot
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(
      decoding: try encoder.encode(
        Export(
          version: Self.versionLabel(version), build: Self.versionLabel(build), snapshot: snapshot()
        )),
      as: UTF8.self)
  }

  private func transition(_ id: RequestID?, from: Phase, to: Phase) {
    guard let id, var request = pending[id], request.record.phase == from else { return }
    request.accrue(until: now())
    request.record.phase = to
    pending[id] = request
  }

  private static func versionLabel(_ value: String) -> String {
    guard !value.isEmpty, value.utf8.count <= 32,
      value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
      })
    else { return "unknown" }
    return value
  }
}
