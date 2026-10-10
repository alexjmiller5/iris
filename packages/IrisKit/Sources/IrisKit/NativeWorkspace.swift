import Foundation
import JavaScriptCore

public typealias JSONValue = CoreJSONValue
public typealias WorkspaceRecord = CoreRow
public typealias WorkspaceRow = CoreWorkspaceRow
public typealias WorkspaceSyncStatus = CoreSyncStatus
public typealias WorkspaceSyncResult = CoreSyncResult

extension CoreJSONValue {
  public var text: String {
    switch self {
    case .string(let value): value
    // Whole numbers read as JavaScript writes them: "1", never "1.0".
    case .number(let value) where value.rounded() == value && abs(value) <= 9_007_199_254_740_991:
      String(Int64(value))
    case .number(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .null: ""
    default: String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
  }
  public var isTrue: Bool { self == .bool(true) || self == .number(1) }
  var isScalar: Bool {
    switch self {
    case .string, .number, .bool: true
    default: false
    }
  }
}
// Forms consume a dictionary projection, not a second wire DTO.
public struct WorkspaceCatalog: Hashable, Sendable {
  public let tables: [WorkspaceRecord]
  public let properties: [WorkspaceRecord]
  public let rules: [WorkspaceRecord]

  init(_ catalog: CoreCatalog) throws {
    tables = catalog.tables
    properties = try JSONDecoder().decode(
      [WorkspaceRecord].self, from: JSONEncoder().encode(catalog.properties))
    rules = catalog.rules
  }
}
extension CoreWorkspaceRow: Identifiable {
  public var id: String { record["id"]?.text ?? "" }
  // SQLite opaque IDs are not Unicode-normalized. Keep wire values as Strings.
  public var byteExactID: Data { Data(id.utf8) }
}
extension CoreSavedViewRecord {
  public var byteExactID: Data { Data(id.utf8) }
}
public struct WorkspaceError: Error, LocalizedError, Sendable {
  public let message: String
  public let violations: [Violation]
  public var errorDescription: String? { message }
}

struct WorkspaceSyncProgress: Equatable, Sendable {
  let phase: String
  let table: String?
  let page: Int
  let processedRows: Int
  let startedAt: Date
  /// Core's account of the round (SyncProgress); zero until core reports.
  var tablesDone = 0
  var tablesTotal = 0
  var rowsReceived = 0
  var rowsExpected: Int? = nil

  /// Seconds left, extrapolated from the share of a full download received.
  /// Nil for a changes-only round, or before 2% and 5 seconds of a download.
  func remaining(at now: Date) -> TimeInterval? {
    guard let rowsExpected, rowsExpected > 0, tablesDone < tablesTotal else { return nil }
    let done = min(Double(rowsReceived) / Double(rowsExpected), 1)
    let elapsed = now.timeIntervalSince(startedAt)
    guard done >= 0.02, elapsed >= 5 else { return nil }
    return elapsed * (1 - done) / done
  }
}

/// Core's SyncProgress, as the bundled runtime reports it.
private struct CoreSyncProgress: Decodable {
  let tablesDone: Int
  let tablesTotal: Int
  let rowsReceived: Int
  let rowsExpected: Int?
  let table: String?
}

/// One request owns the database until its promise settles or awaits HTTP outside a transaction.
/// MainActor alone is insufficient: it is reentrant at each awaited SQL call.
@MainActor
public final class NativeWorkspace {
  private let runtime: IrisCoreRuntime
  private let database: SQLiteBridge
  private let fileGate: WorkspaceFileGate
  private let path: String
  private var syncLock: SyncFileLock?
  private enum Work {
    case request(Request)
    case resumeTransport(Int, JSValue, String)
  }
  private var requests: [Work] = []
  private var active: Request?
  /// When foreground (non-passive) work last arrived or finished. Background index steps
  /// wait for a quiet moment, so a burst of reads (a table open) never queues behind one.
  private(set) var lastForegroundActivity = ContinuousClock.now
  private var suspended: [Int: Request] = [:]
  private var networks: [Int: Task<Void, Never>] = [:]
  private var nextID = 0
  private var closing = false
  private var closed = false
  private var droppedOnClose: [String] = []
  private let diagnostics = NativeWorkspaceDiagnostics()
  // Backup files opened by core during the active request; closed or abandoned at completion.
  private var dumpReaders: [Int: DumpFileReader] = [:]
  private var dumpWriters: [Int: DumpFileWriter] = [:]
  private var nextDump = 0
  private var backupOpens = 0
  /// Phase, bytes done and bytes total (0 when unknown) of a long backup action.
  var onBackupProgress: ((String, Int64, Int64) -> Void)?
  private var progressReported = ContinuousClock.now
  private var referenceReadPending = false
  private var referenceWaiters: [(UUID, CheckedContinuation<Void, Error>)] = [] {
    didSet { diagnostics.setPassiveGateWaiterCount(referenceWaiters.count) }
  }

  private struct Request {
    let id: Int
    let method: String
    let arguments: String
    let transport: HubTransport?
    let continuation: CheckedContinuation<JSONValue, Error>
    let control: SyncControl?
    let readAdmission: ReadAdmission?
    let referenceRead: Bool
    let diagnosticID: NativeWorkspaceDiagnostics.RequestID?
  }
  /// onCancel can run off the main actor. Admission and cancellation share one
  /// decision; cancellation never changes an operation already admitted.
  private final class ReadAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var admitted = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { if !admitted { cancelled = true } } }
    func admit() -> Bool {
      lock.withLock {
        guard !cancelled else { return false }
        admitted = true
        return true
      }
    }
  }
  @MainActor private final class SyncControl {
    let timeout: Duration
    let onProgress: ((WorkspaceSyncProgress) -> Void)?
    var startedAt = Date()
    var cancelled = false
    var network: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var page = 0
    var processedRows = 0
    var table: String?
    var phase = "Connecting"
    var core: CoreSyncProgress?
    init(timeout: Duration, onProgress: ((WorkspaceSyncProgress) -> Void)?) {
      self.timeout = timeout
      self.onProgress = onProgress
    }
    func report(_ phase: String) {
      self.phase = phase
      onProgress?(
        WorkspaceSyncProgress(
          phase: phase, table: table, page: page,
          processedRows: processedRows, startedAt: startedAt,
          tablesDone: core?.tablesDone ?? 0, tablesTotal: core?.tablesTotal ?? 0,
          rowsReceived: core?.rowsReceived ?? 0, rowsExpected: core?.rowsExpected))
    }
  }
  private struct Reply: Decodable {
    let value: JSONValue?
    let error: String?
    let violations: [Violation]?
  }

  public convenience init(path: String) throws {
    try self.init(path: path, runtime: IrisCoreRuntime())
  }

  init(path: String, runtime: IrisCoreRuntime) throws {
    guard
      runtime.context.objectForKeyedSubscript("IrisNative")?.forProperty("contractHash")?.toString()
        == CoreContract.hash
    else {
      throw WorkspaceError(
        message: "Core contract does not match the bundled runtime.", violations: [])
    }
    let opened = try WorkspaceFileGate.open(path)
    self.path = opened.gate.path
    self.runtime = runtime
    database = opened.database
    fileGate = opened.gate
    try database.install(in: runtime.context)
    database.onExecution = { [weak self] milliseconds in
      guard let self else { return }
      self.diagnostics.addMetrics(
        .init(sqlMilliseconds: milliseconds, sqlCount: 1), to: self.active?.diagnosticID)
    }
    let finish: @convention(block) (Int, String) -> Void = { [weak self] id, json in
      self?.finish(id: id, json: json)
    }
    let yield: @convention(block) (JSValue) -> Void = { [weak self] callback in
      guard let request = self?.active else { return }
      let started = ContinuousClock.now
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.diagnostics.addMetrics(
          .init(yieldGapMilliseconds: Self.elapsedMilliseconds(since: started)),
          to: request.diagnosticID)
        self?.invokeCallback(callback, owner: request.id, arguments: [])
      }
    }
    let post: @convention(block) (String, String, JSValue) -> Void = {
      [weak self] route, json, callback in
      guard let self, let owner = self.active, let transport = owner.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
        return
      }
      if self.closing {
        callback.call(withArguments: [Self.closingReply])
        return
      }
      if owner.control?.cancelled == true {
        callback.call(withArguments: [#"{"error":"Sync cancelled. Local changes are retained."}"#])
        return
      }
      do { try self.suspendForTransport(owner) } catch {
        callback.call(withArguments: [
          #"{"error":"Network request attempted inside a transaction."}"#
        ])
        return
      }
      let network = Task { @MainActor in
        let response: String
        do {
          let body = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
          if let control = owner.control {
            // A batched pull names many tables; keep the one core reports.
            let table = body["table"]?.text ?? (body["batch"] == nil ? nil : control.table)
            let phase =
              route.contains("schema")
              ? "Schema"
              : route == "/v1/stats"
                ? "Planning"
                : route == "/v1/cursor"
                  ? "Checkpoint" : route.hasSuffix("/pull") ? "Downloading" : "Uploading"
            if control.table != table || control.phase != phase { control.page = 0 }
            control.table = table
            if route == "/v1/rows/pull" || route == "/v1/rows/push" { control.page += 1 }
            control.report(phase)
          }
          let reply = try await transport.post(route: route, body: body)
          if let control = owner.control, case .object(let data) = reply.data {
            if case .array(let rows) = data["rows"] { control.processedRows += rows.count }
            if case .array(let pages) = data["batch"] {
              for case .object(let page) in pages {
                if case .array(let rows) = page["rows"] { control.processedRows += rows.count }
              }
            }
            if case .number(let accepted) = data["upserted"], accepted >= 0,
              accepted <= 200, accepted.rounded() == accepted
            {
              control.processedRows += Int(accepted)
            }
            control.report(control.phase)
          }
          response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        } catch {
          response = String(
            decoding: try! JSONEncoder().encode(["error": error.localizedDescription]),
            as: UTF8.self)
        }
        self.receiveTransport(owner: owner.id, callback: callback, response: response)
      }
      owner.control?.network = network
      self.networks[owner.id] = network
    }
    runtime.context.setObject(post, forKeyedSubscript: "__irisPost" as NSString)
    let progress: @convention(block) (String) -> Void = { [weak self] json in
      guard let control = self?.active?.control,
        let state = try? JSONDecoder().decode(CoreSyncProgress.self, from: Data(json.utf8))
      else { return }
      control.core = state
      if let table = state.table { control.table = table }
      control.report(control.phase)
    }
    runtime.context.setObject(progress, forKeyedSubscript: "__irisSyncProgress" as NSString)
    let get: @convention(block) (String, JSValue) -> Void = { [weak self] route, callback in
      guard let self, let owner = self.active, let transport = owner.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
        return
      }
      if self.closing {
        callback.call(withArguments: [Self.closingReply])
        return
      }
      do { try self.suspendForTransport(owner) } catch {
        callback.call(withArguments: [
          #"{"error":"Network request attempted inside a transaction."}"#
        ])
        return
      }
      self.networks[owner.id] = Task { @MainActor in
        let response: String
        do {
          let reply = try await transport.get(route: route)
          response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        } catch {
          response = String(
            decoding: try! JSONEncoder().encode(["error": error.localizedDescription]),
            as: UTF8.self)
        }
        self.receiveTransport(owner: owner.id, callback: callback, response: response)
      }
    }
    runtime.context.setObject(get, forKeyedSubscript: "__irisGet" as NSString)
    runtime.context.setObject(finish, forKeyedSubscript: "__irisFinish" as NSString)
    runtime.context.setObject(yield, forKeyedSubscript: "__irisYield" as NSString)
    installDumpBridge()
  }

  /// Core's BackupFiles adapter. References are file paths this host put in the
  /// request arguments; gzip and UTF-8 are handled here, never in core.
  private func installDumpBridge() {
    let fail: (String) -> Void = { [weak self] message in
      guard let context = self?.runtime.context else { return }
      context.exception = JSValue(newErrorFromMessage: message, in: context)
    }
    let open: @convention(block) (String) -> Int = { [weak self] path in
      guard let self, self.active != nil, path.hasPrefix("/") else {
        fail("Backup files are available only during a backup request.")
        return -1
      }
      do {
        let reader = try DumpFileReader(url: URL(fileURLWithPath: path))
        self.backupOpens += 1
        self.nextDump += 1
        self.dumpReaders[self.nextDump] = reader
        return self.nextDump
      } catch { fail(error.localizedDescription) }
      return -1
    }
    let read: @convention(block) (Int) -> Any = { [weak self] id in
      guard let self, let reader = self.dumpReaders[id] else {
        fail("The backup file is closed.")
        return NSNull()
      }
      do {
        guard let text = try reader.next() else {
          self.dumpReaders[id] = nil
          return NSNull()
        }
        let restoring = self.active?.method == "restoreReplica" && self.backupOpens > 1
        self.reportBackup(
          restoring ? "Restoring" : "Checking backup", reader.readBytes, reader.totalBytes)
        return text
      } catch {
        self.dumpReaders[id] = nil
        fail(error.localizedDescription)
        return NSNull()
      }
    }
    let create: @convention(block) (String) -> Int = { [weak self] path in
      guard let self, self.active != nil, path.hasPrefix("/") else {
        fail("Backup files are available only during a backup request.")
        return -1
      }
      do {
        let writer = try DumpFileWriter(url: URL(fileURLWithPath: path))
        self.nextDump += 1
        self.dumpWriters[self.nextDump] = writer
        return self.nextDump
      } catch { fail(error.localizedDescription) }
      return -1
    }
    let write: @convention(block) (Int, String) -> Void = { [weak self] id, text in
      guard let self, let writer = self.dumpWriters[id] else {
        return fail("The backup file is closed.")
      }
      do {
        try writer.write(text)
        let phase = self.active?.method == "restoreReplica" ? "Saving recovery copy" : "Exporting"
        self.reportBackup(phase, writer.writtenBytes, 0)
      } catch { fail("The backup could not be written: \(error.localizedDescription)") }
    }
    let close: @convention(block) (Int) -> Void = { [weak self] id in
      guard let self else { return }
      self.dumpReaders[id] = nil
      guard let writer = self.dumpWriters.removeValue(forKey: id) else { return }
      do { try writer.close() } catch {
        writer.abandon()
        fail("The backup could not be saved: \(error.localizedDescription)")
      }
    }
    for (name, function) in [
      ("__irisDumpOpen", open as Any), ("__irisDumpRead", read), ("__irisDumpCreate", create),
      ("__irisDumpWrite", write), ("__irisDumpClose", close),
    ] {
      runtime.context.setObject(function, forKeyedSubscript: name as NSString)
    }
  }

  private func reportBackup(_ phase: String, _ done: Int64, _ total: Int64) {
    guard let onBackupProgress, progressReported.duration(to: .now) > .milliseconds(200) else {
      return
    }
    progressReported = .now
    onBackupProgress(phase, done, total)
  }

  /// The whole catalog is about a megabyte on a large estate; its revision is one short read.
  private var cachedCatalog: (revision: String, catalog: WorkspaceCatalog)?
  public func catalog() async throws -> WorkspaceCatalog {
    // Read before the catalog: a change committed in between only costs the next read.
    let revision = try await decode(
      CoreRequests.CatalogRevision(CoreEmptyArgs()), cancellableRead: true
    ).revision
    if let cachedCatalog, cachedCatalog.revision == revision { return cachedCatalog.catalog }
    var id: NativeWorkspaceDiagnostics.RequestID?
    let catalog = try await decode(
      CoreRequests.Catalog(CoreEmptyArgs()), cancellableRead: true, onDiagnosticID: { id = $0 })
    let started = ContinuousClock.now
    defer {
      diagnostics.addMetrics(
        .init(decodeMilliseconds: Self.elapsedMilliseconds(since: started)), to: id)
    }
    let decoded = try WorkspaceCatalog(catalog)
    cachedCatalog = (revision, decoded)
    return decoded
  }
  /// Explicit capture only. Never submits a database request, even while navigation waits.
  func diagnosticReport(version: String, build: String) throws -> String {
    try diagnostics.snapshotJSON(version: version, build: build)
  }
  public func writeability(table: String) async throws -> CoreWriteability {
    try await decode(CoreRequests.Writeability(CoreWriteabilityArgs(table: table)))
  }
  public func rows(view: CoreView) async throws -> [WorkspaceRow] {
    try await decode(CoreRequests.Rows(view), cancellableRead: true)
  }
  /// Reads that only fill presentation, such as reference labels in displayed rows.
  func passiveRead<R: CoreRequest>(_ request: R) async throws -> R.Response {
    try Task.checkCancellation()
    try await acquireReferenceRead()
    defer { releaseReferenceRead() }
    try Task.checkCancellation()
    return try await decode(request, cancellableRead: true, referenceRead: true)
  }
  private struct LabelWaiter {
    let id: UUID
    let targets: [CoreRecordTarget]
    let continuation: CheckedContinuation<[CoreMentionLabel], Error>
  }
  private var labelWaiters: [LabelWaiter] = []
  private var labelFlushScheduled = false
  /// Display labels for reference cells. Cells rendered together share one passive
  /// read of at most 200 targets instead of one row read each.
  func referenceLabels(_ targets: [CoreRecordTarget]) async throws -> [CoreMentionLabel] {
    try Task.checkCancellation()
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        labelWaiters.append(LabelWaiter(id: id, targets: targets, continuation: continuation))
        guard !labelFlushScheduled else { return }
        labelFlushScheduled = true
        // Runs after the cell tasks already scheduled by the same rendering pass.
        Task { @MainActor [weak self] in await self?.flushReferenceLabels() }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, let index = self.labelWaiters.firstIndex(where: { $0.id == id }) else {
          return
        }
        self.labelWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
      }
    }
  }
  private func flushReferenceLabels() async {
    labelFlushScheduled = false
    let waiters = labelWaiters
    labelWaiters = []
    func key(_ target: CoreRecordTarget) -> [Data] {
      [Data(target.table.utf8), Data(target.id.utf8)]
    }
    var seen = Set<[Data]>()
    let targets = waiters.flatMap(\.targets).filter { seen.insert(key($0)).inserted }
    var found: [[Data]: CoreMentionLabel] = [:]
    do {
      for start in stride(from: 0, to: targets.count, by: 200) {
        let chunk = Array(targets[start..<min(start + 200, targets.count)])
        for label in try await passiveRead(
          CoreRequests.MentionLabels(CoreMentionLabelsArgs(targets: chunk)))
        {
          found[key(CoreRecordTarget(table: label.table, id: label.id))] = label
        }
      }
      for waiter in waiters {
        waiter.continuation.resume(returning: waiter.targets.compactMap { found[key($0)] })
      }
    } catch {
      for waiter in waiters { waiter.continuation.resume(throwing: error) }
    }
  }
  /// Keep presentation fan-out outside the database queue. A transport or HTTP
  /// resumption barrier can then have at most one passive read ahead of it.
  private func acquireReferenceRead() async throws {
    if !referenceReadPending {
      referenceReadPending = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        referenceWaiters.append((id, continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, let index = self.referenceWaiters.firstIndex(where: { $0.0 == id }) else {
          return
        }
        self.referenceWaiters.remove(at: index).1.resume(throwing: CancellationError())
      }
    }
  }
  private func releaseReferenceRead() {
    if referenceWaiters.isEmpty {
      referenceReadPending = false
    } else {
      referenceWaiters.removeFirst().1.resume()
    }
  }
  public func rows(table: String, search: String = "", trash: Bool = false, offset: Int = 0)
    async throws -> [WorkspaceRow]
  {
    try await rows(
      view: CoreView(table: table, limit: 100, offset: offset, trash: trash, search: search))
  }
  public func options(table: String, column: String) async throws -> [String] {
    try await decode(CoreRequests.Options(CoreOptionsArgs(table: table, column: column)))
  }
  public func referenceSources(_ args: CoreReferenceSourcesArgs) async throws
    -> [CoreReferenceSource]
  {
    try await decode(CoreRequests.ReferenceSources(args))
  }
  public func referencedBy(_ args: CoreReferencedByArgs) async throws -> CoreReferencedByPage {
    let preference = try await getRelatedViewDefault(table: args.sourceTable)
    var request = args
    if request.expectedViewUpdatedAt == nil {
      request.expectedViewUpdatedAt = preference.view?.updatedAt
    }
    if request.calendar == nil, let definition = preference.view?.definition,
      let zone = definition.timeZone
    {
      request.calendar = try calendarContext(
        timeZone: zone, dayStartMinutes: definition.dayStartMinutes ?? 0)
    }
    return try await decode(CoreRequests.ReferencedBy(request))
  }

  public func mentionedBy(_ args: CoreMentionedByArgs) async throws -> CoreMentionedByPage {
    try await decode(CoreRequests.MentionedBy(args))
  }
  /// The Markdown island's only data reads: labels, embeds and its pickers.
  static let editorReadOperations: Set<String> = [
    "catalog", "search", "listViews", "mentionLabels", "viewEmbed",
  ]
  func editorRead(_ method: String, arguments: String) async throws -> JSONValue {
    guard Self.editorReadOperations.contains(method) else {
      throw WorkspaceError(message: "The editor cannot request this operation.", violations: [])
    }
    return try await call(method, arguments: arguments, cancellableRead: true)
  }
  public func resolveSourceLink(_ url: String) async throws -> CoreSourceLinkResult {
    try await decode(CoreRequests.ResolveSourceLink(CoreSourceLinkArgs(url: url)))
  }
  /// A superseded search still waiting for the database is dropped, not run.
  public func search(_ args: CoreSearchArgs) async throws -> [CoreSearchHit] {
    try await decode(CoreRequests.Search(args), cancellableRead: true)
  }
  /// One bounded step of the search index, the only thing that builds it. Queued as a
  /// passive request, so foreground work submitted after it runs first.
  public func searchIndexStep(budgetMs: Int) async throws -> CoreSearchIndexStatus {
    try await decode(
      CoreRequests.SearchIndexStep(CoreSearchIndexStepArgs(budgetMs: budgetMs)),
      referenceRead: true)
  }
  public func listSidebarPins() async throws -> CoreSidebarPinList {
    try await decode(CoreRequests.ListSidebarPins(CoreEmptyArgs()))
  }
  public func prepareReadPlan(_ args: CorePrepareReadPlanArgs) async throws -> CoreReadPlan {
    try await decode(CoreRequests.PrepareReadPlan(args), cancellableRead: true)
  }
  public func exportWidgetSnapshot(to url: URL) async throws {
    guard url.isFileURL else {
      throw WorkspaceError(message: "Widget snapshot requires a file destination.", violations: [])
    }
    _ = try await call(
      "widgetBackup", arguments: String(decoding: JSONEncoder().encode(url.path), as: UTF8.self),
      cancellableRead: true)
  }
  /// A consistent SQLite copy of this workspace's file, for saving or sharing.
  public func copyReplica(to url: URL) async throws {
    guard url.isFileURL else {
      throw WorkspaceError(message: "The copy needs a file destination.", violations: [])
    }
    _ = try await call(
      "replicaBackup", arguments: String(decoding: JSONEncoder().encode(url.path), as: UTF8.self))
  }
  public func exportReplica(to url: URL) async throws -> CoreBackupSummary {
    try await decode(CoreRequests.ExportReplica(CoreBackupFileArgs(file: url.path)))
  }
  public func validateBackup(file: URL) async throws -> CoreBackupSummary {
    try await decode(CoreRequests.ValidateBackup(CoreBackupFileArgs(file: file.path)))
  }
  public func previewRestore(file: URL) async throws -> CoreRestorePreview {
    try await decode(CoreRequests.PreviewRestore(CoreBackupFileArgs(file: file.path)))
  }
  /// Callers pass the confirmation word the user typed; core refuses anything else.
  public func restoreReplica(file: URL, recovery: URL, confirm: String) async throws
    -> CoreRestoreResult
  {
    try await decode(
      CoreRequests.RestoreReplica(
        CoreRestoreArgs(file: file.path, recovery: recovery.path, confirm: confirm)))
  }
  func hubBackups(using transport: HubTransport) async throws -> CoreHubBackupList {
    try await decode(
      CoreRequests.HubBackups(CoreEndpointArgs(endpoint: transport.endpoint)), transport: transport)
  }
  func createHubBackup(using transport: HubTransport) async throws -> CoreHubBackup {
    try await decode(
      CoreRequests.CreateHubBackup(CoreEndpointArgs(endpoint: transport.endpoint)),
      transport: transport)
  }
  public func pinTable(_ args: CorePinTableArgs) async throws -> CoreSidebarPinList {
    try await decode(CoreRequests.PinTable(args))
  }
  public func unpinTable(_ args: CoreUnpinTableArgs) async throws -> CoreSidebarPinList {
    try await decode(CoreRequests.UnpinTable(args))
  }
  public func moveTablePin(_ args: CoreMoveTablePinArgs) async throws -> CoreSidebarPinList {
    try await decode(CoreRequests.MoveTablePin(args))
  }
  @discardableResult public func prepareLocalPins() async throws -> Bool {
    guard case .bool(let created) = try await call("prepareLocalPins") else {
      throw WorkspaceError(message: "Invalid pin setup response.", violations: [])
    }
    return created
  }
  func resolveViewDefinition(table: String, definition: WorkspaceRecord) async throws
    -> CoreResolvedViewDefinition
  {
    let args: WorkspaceRecord = ["table": .string(table), "definition": .object(definition)]
    let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
    let result = try await call("resolveViewDefinition", arguments: json)
    return try JSONDecoder().decode(
      CoreResolvedViewDefinition.self, from: JSONEncoder().encode(result))
  }
  public func listViews(table: String) async throws -> CoreSavedViewList {
    try await decode(CoreRequests.ListViews(CoreListViewsArgs(table: table)))
  }
  public func getViewDefault(table: String) async throws -> CoreViewDefault {
    try await decode(CoreRequests.GetViewDefault(CoreGetViewDefaultArgs(table: table)))
  }
  public func ensureDefaultView(table: String) async throws -> CoreViewDefault {
    try await decode(CoreRequests.EnsureDefaultView(CoreGetViewDefaultArgs(table: table)))
  }
  public func setViewDefault(_ args: CoreSetViewDefaultArgs) async throws -> CoreViewDefault {
    try await decode(CoreRequests.SetViewDefault(args))
  }
  public func getRelatedViewDefault(table: String) async throws -> CoreViewDefault {
    try await decode(CoreRequests.GetRelatedViewDefault(CoreGetViewDefaultArgs(table: table)))
  }
  public func setRelatedViewDefault(_ args: CoreSetViewDefaultArgs) async throws -> CoreViewDefault
  {
    try await decode(CoreRequests.SetRelatedViewDefault(args))
  }
  func saveCatalogProperty(_ args: CoreSaveCatalogPropertyArgs) async throws -> WorkspaceRecord {
    let result = try await decode(CoreRequests.SaveCatalogProperty(args))
    return try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(result))
  }
  func saveCatalogRule(_ args: CoreSaveCatalogRuleArgs) async throws -> WorkspaceRecord {
    try await decode(CoreRequests.SaveCatalogRule(args))
  }
  @discardableResult
  func prepareLocalCatalog() async throws -> Bool {
    guard case .bool(let created) = try await call("prepareLocalCatalog") else {
      throw WorkspaceError(message: "Invalid catalog setup response.", violations: [])
    }
    return created
  }
  public func saveView(_ args: CoreSaveViewArgs) async throws -> CoreSavedViewRecord {
    try await decode(CoreRequests.SaveView(args))
  }
  public func deleteView(_ args: CoreDeleteViewArgs) async throws -> CoreSavedViewRecord {
    try await decode(CoreRequests.DeleteView(args))
  }
  public func write(table: String, patch: WorkspaceRecord, expectedUpdatedAt: String? = nil)
    async throws -> WorkspaceRecord
  {
    try await decode(
      CoreRequests.Write(
        CoreWriteArgs(table: table, patch: patch, expectedUpdatedAt: expectedUpdatedAt)))
  }
  public func rejections(_ args: CoreRejectionsArgs = CoreRejectionsArgs()) async throws
    -> CoreRejectionsPage
  {
    try await decode(CoreRequests.Rejections(args))
  }
  public func status() async throws -> WorkspaceSyncStatus {
    try await decode(CoreRequests.Status(CoreEmptyArgs()))
  }
  public func runRowAction(_ args: CoreRunRowActionArgs) async throws -> WorkspaceRecord {
    try await decode(CoreRequests.RunRowAction(args))
  }
  public func undoStatus() async throws -> CoreUndoStatus {
    try await decode(CoreRequests.UndoStatus(CoreEmptyArgs()))
  }
  public func undo(receiptID: String) async throws -> WorkspaceRecord {
    try await decode(CoreRequests.Undo(CoreUndoArgs(receiptId: receiptID)))
  }

  func usage(using transport: HubTransport) async throws -> UsageSummary {
    try await decode(
      CoreRequests.ServiceUsage(CoreEndpointArgs(endpoint: transport.endpoint)),
      transport: transport)
  }
  func notifications(using transport: HubTransport) async throws -> NotificationFeed {
    try await decode(
      CoreRequests.ServiceNotifications(CoreEndpointArgs(endpoint: transport.endpoint)),
      transport: transport)
  }
  func markNotificationsRead(using transport: HubTransport, selector: WorkspaceRecord) async throws
    -> NotificationReadResult
  {
    let typed = try JSONDecoder().decode(
      CoreNotificationReadSelector.self, from: JSONEncoder().encode(selector))
    return try await markNotificationsRead(using: transport, selector: typed)
  }
  func markNotificationsRead(using transport: HubTransport, selector: CoreNotificationReadSelector)
    async throws
    -> NotificationReadResult
  {
    try await decode(
      CoreRequests.MarkNotificationsRead(
        CoreNotificationReadArgs(endpoint: transport.endpoint, selector: selector)),
      transport: transport)
  }
  func notificationPresentation(_ feed: NotificationFeed, baseline: Int?) async throws
    -> NotificationPresentation
  {
    try await decode(
      CoreRequests.NotificationPresentation(
        CoreNotificationPresentationArgs(feed: feed, baseline: baseline)))
  }

  func resolveDerived(
    using transport: HubTransport, table: String, id: String,
    column: String, expectedUpdatedAt: String
  ) async throws -> CoreResolveDerivedResult {
    try await decode(
      CoreRequests.ResolveDerived(
        CoreResolveDerivedArgs(
          endpoint: transport.endpoint, table: table, id: id, column: column,
          expectedUpdatedAt: expectedUpdatedAt)), transport: transport)
  }

  func calendarRows(_ args: CoreCalendarRowsArgs) async throws -> CoreCalendarRowsResult {
    try await decode(CoreRequests.CalendarRows(args))
  }

  func boardRows(_ args: CoreBoardRowsArgs) async throws -> CoreBoardRowsResult {
    try await decode(CoreRequests.BoardRows(args))
  }

  func remoteRows(
    using transport: HubTransport, table: String, limit: Int = 50, cursor: String? = nil
  )
    async throws -> CoreRemoteRowsPage
  {
    try await decode(
      CoreRequests.RemoteRows(
        CoreRemoteRowsArgs(
          endpoint: transport.endpoint, table: table, limit: limit, cursor: cursor)),
      transport: transport)
  }

  func remoteRow(using transport: HubTransport, table: String, id: String) async throws
    -> CoreRemoteRowResult
  {
    try await decode(
      CoreRequests.RemoteRow(CoreRemoteRowArgs(endpoint: transport.endpoint, table: table, id: id)),
      transport: transport)
  }

  func sync(
    using transport: HubTransport, maxRows: Int? = nil, tables: [String: Bool]? = nil,
    timeout: Duration = .seconds(900), onProgress: ((WorkspaceSyncProgress) -> Void)? = nil
  )
    async throws
    -> WorkspaceSyncResult
  {
    try await decode(
      CoreRequests.Sync(
        CoreSyncArgs(endpoint: transport.endpoint, maxRows: maxRows, tables: tables)),
      transport: transport, control: SyncControl(timeout: timeout, onProgress: onProgress))
  }
  func cancelSync() {
    let control =
      suspended.values.first(where: { $0.method == "sync" })?.control
      ?? (active?.method == "sync" ? active?.control : nil)
    control?.cancelled = true
    control?.network?.cancel()
  }
  public func createSample() async throws { _ = try await call("sample") }
  /// Bootstrap only a database owned by this app. Replicas receive schema through sync.
  @discardableResult
  public func prepareLocalViews() async throws -> Bool {
    guard case .bool(let created) = try await call("prepareLocalViews") else {
      throw WorkspaceError(message: "Invalid local setup response.", violations: [])
    }
    return created
  }
  /// Close refuses new HTTP and cancels every outstanding transport, so each
  /// suspended owner unwinds through the queue before SQLite closes. An owner
  /// still suspended after `grace` is failed and dropped; the result names the
  /// dropped methods. Close never waits on a hub response beyond `grace`.
  @discardableResult
  public func close(grace: Duration = .seconds(5)) async throws -> [String] {
    closing = true
    for network in networks.values { network.cancel() }
    let deadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: grace) } catch { return }
      self?.dropSuspended()
    }
    defer { deadline.cancel() }
    if grace <= .zero { dropSuspended() }
    do { _ = try await call("close") } catch {
      closing = false
      throw error
    }
    return droppedOnClose
  }
  private static let closingReply = #"{"error":"The workspace is closing."}"#
  private func dropSuspended() {
    for (id, owner) in suspended.sorted(by: { $0.key < $1.key }) {
      suspended[id] = nil
      networks.removeValue(forKey: id)?.cancel()
      owner.control?.deadline?.cancel()
      if owner.method == "sync" { syncLock = nil }
      diagnostics.finish(owner.diagnosticID)
      droppedOnClose.append(owner.method)
      owner.continuation.resume(
        throwing: WorkspaceError(
          message: "The workspace closed before the hub replied.", violations: []))
    }
    startNext()
  }

  private func decode<R: CoreRequest>(
    _ request: R, transport: HubTransport? = nil, control: SyncControl? = nil,
    cancellableRead: Bool = false, referenceRead: Bool = false,
    onDiagnosticID: ((NativeWorkspaceDiagnostics.RequestID?) -> Void)? = nil
  ) async throws
    -> R.Response
  {
    let arguments = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
    var id: NativeWorkspaceDiagnostics.RequestID?
    let value = try await call(
      R.method, arguments: arguments, transport: transport, control: control,
      cancellableRead: cancellableRead, referenceRead: referenceRead,
      onDiagnosticID: {
        id = $0
        onDiagnosticID?($0)
      })
    let started = ContinuousClock.now
    defer {
      diagnostics.addMetrics(
        .init(decodeMilliseconds: Self.elapsedMilliseconds(since: started)), to: id)
    }
    return try JSONDecoder().decode(R.Response.self, from: JSONEncoder().encode(value))
  }
  private func call(
    _ method: String, arguments: String = "{}", transport: HubTransport? = nil,
    control: SyncControl? = nil, cancellableRead: Bool = false, referenceRead: Bool = false,
    onDiagnosticID: ((NativeWorkspaceDiagnostics.RequestID?) -> Void)? = nil
  ) async throws -> JSONValue {
    guard !closed else { throw WorkspaceError(message: "Workspace is closed.", violations: []) }
    let readAdmission = cancellableRead ? ReadAdmission() : nil
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard readAdmission?.isCancelled != true else {
          continuation.resume(throwing: CancellationError())
          return
        }
        nextID += 1
        let diagnosticID = NativeWorkspaceDiagnostics.Method(rawValue: method).flatMap {
          diagnostics.enqueue(method: $0, isForeground: !referenceRead)
        }
        onDiagnosticID?(diagnosticID)
        var insertion = requests.endIndex
        if !referenceRead, transport == nil, method != "sync", method != "close",
          method != "widgetBackup", method != "replicaBackup"
        {
          // Local foreground work may pass only trailing passive-label reads.
          // Foreground FIFO, transport, sync, close and HTTP resumptions stay ordered.
          while insertion > requests.startIndex {
            guard case .request(let queued) = requests[insertion - 1], queued.referenceRead else {
              break
            }
            insertion -= 1
          }
        }
        if !referenceRead { lastForegroundActivity = .now }
        requests.insert(
          .request(
            Request(
              id: nextID, method: method, arguments: arguments, transport: transport,
              continuation: continuation, control: control, readAdmission: readAdmission,
              referenceRead: referenceRead, diagnosticID: diagnosticID)), at: insertion)
        startNext()
      }
    } onCancel: {
      readAdmission?.cancel()
    }
  }
  fileprivate func startNext() {
    guard active == nil, !requests.isEmpty else { return }
    var index = 0
    if suspended.values.contains(where: { $0.method == "sync" }) {
      // A queued second sync must not block local work behind it. Never skip
      // close: calls submitted after close retain their original ordering.
      while index < requests.count {
        if case .request(let request) = requests[index], request.method == "sync" {
          index += 1
        } else {
          break
        }
      }
      guard index < requests.count else { return }
    }
    // An instance waiting for its own HTTP must not reserve the shared file.
    if case .request(let request) = requests[index], request.method == "close",
      !suspended.isEmpty
    {
      return
    }
    guard fileGate.acquire(self) else { return }
    if case .resumeTransport(let id, let callback, let response) = requests[index] {
      requests.remove(at: index)
      guard let owner = suspended.removeValue(forKey: id) else {
        fileGate.release(self)
        Task { @MainActor [self] in startNext() }
        return
      }
      active = owner
      diagnostics.admit(owner.diagnosticID)
      invokeCallback(callback, owner: id, arguments: [response])
      return
    }
    guard case .request(let request) = requests[index] else { return }
    requests.remove(at: index)
    active = request
    diagnostics.admit(request.diagnosticID)
    // Keep cancelled placeholders until their normal file turn: removing every
    // request from a waiting instance could strand its reserved gate ownership.
    if request.readAdmission?.admit() == false {
      complete(.failure(CancellationError()))
      return
    }
    if closed {
      complete(.failure(WorkspaceError(message: "Workspace is closed.", violations: [])))
      return
    }
    if request.method == "close" {
      do {
        try database.close()
        closed = true
        complete(.success(.null))
      } catch { complete(.failure(error)) }
      return
    }
    do { try database.prepareForRequests() } catch {
      complete(.failure(error))
      return
    }
    if request.method == "widgetBackup" || request.method == "replicaBackup" {
      do {
        let path = try JSONDecoder().decode(String.self, from: Data(request.arguments.utf8))
        let widget = request.method == "widgetBackup"
        Task { [self] in
          do {
            try await database.exportWidgetSnapshot(
              to: URL(fileURLWithPath: path), budget: widget ? 536_870_912 : nil,
              deadline: widget ? .seconds(5) : nil)
            complete(.success(.null))
          } catch { complete(.failure(error)) }
        }
      } catch { complete(.failure(error)) }
      return
    }
    if request.method == "sync", path != ":memory:" {
      do { syncLock = try SyncFileLock(databasePath: path) } catch {
        complete(.failure(error))
        return
      }
    }
    if let control = request.control {
      control.startedAt = Date()
      control.report("Connecting")
      control.deadline = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: control.timeout) } catch { return }
        guard self?.active?.id == request.id || self?.suspended[request.id] != nil else { return }
        self?.cancelSync()
      }
    }
    runtime.context.exception = nil
    runtime.context.objectForKeyedSubscript("IrisNative")?.invokeMethod(
      "request", withArguments: [request.id, request.method, request.arguments])
    if let exception = runtime.context.exception {
      complete(.failure(WorkspaceError(message: exception.toString(), violations: [])))
    }
  }
  private func finish(id: Int, json: String) {
    guard active?.id == id else { return }
    let diagnosticID = active?.diagnosticID
    let started = ContinuousClock.now
    let data = Data(json.utf8)
    defer {
      diagnostics.addMetrics(
        .init(
          decodeMilliseconds: Self.elapsedMilliseconds(since: started), responseBytes: data.count),
        to: diagnosticID)
    }
    do {
      let reply = try JSONDecoder().decode(Reply.self, from: data)
      if let error = reply.error {
        complete(.failure(WorkspaceError(message: error, violations: reply.violations ?? [])))
      } else {
        complete(.success(reply.value ?? .null))
      }
    } catch { complete(.failure(error)) }
  }
  private func complete(_ result: Result<JSONValue, Error>) {
    if active?.referenceRead == false { lastForegroundActivity = .now }
    var outcome = result
    if !closed, database.isInsideTransaction {
      do {
        try database.rollbackUnfinishedTransaction()
        if case .success = outcome {
          outcome = .failure(
            WorkspaceError(
              message: "The operation ended before its transaction committed.", violations: []))
        }
      } catch { outcome = .failure(error) }
    }
    if active?.method == "sync" {
      syncLock = nil
      active?.control?.deadline?.cancel()
    }
    // A finished request never leaves a backup file open or a partial copy behind.
    dumpReaders.removeAll()
    for writer in dumpWriters.values { writer.abandon() }
    dumpWriters.removeAll()
    backupOpens = 0
    let continuation = active?.continuation
    diagnostics.finish(active?.diagnosticID)
    active = nil
    fileGate.release(self)
    continuation?.resume(with: outcome)
    // Do not reenter JSC from inside its completion callback.
    Task { @MainActor [self] in startNext() }
  }

  private func suspendForTransport(_ owner: Request) throws {
    guard suspended[owner.id] == nil, !database.isInsideTransaction else {
      throw WorkspaceError(
        message: "Network request attempted inside a transaction.", violations: [])
    }
    suspended[owner.id] = owner
    diagnostics.suspend(owner.diagnosticID)
    active = nil
    fileGate.release(self)
    // Leave the current JSC callback before starting another JS operation.
    Task { @MainActor [self] in startNext() }
  }

  private func receiveTransport(owner: Int, callback: JSValue, response: String) {
    networks[owner] = nil
    if let request = suspended[owner] {
      request.control?.network = nil
      diagnostics.resume(request.diagnosticID)
      // Resume behind admitted foreground work, but ahead of barriers waiting
      // for this sync itself. No callback can run inside a foreground transaction.
      let barrier =
        requests.firstIndex { work in
          if case .request(let request) = work {
            return ["sync", "close"].contains(request.method)
          }
          return false
        } ?? requests.endIndex
      requests.insert(.resumeTransport(owner, callback, response), at: barrier)
      Task { @MainActor [self] in startNext() }
    } else if active?.id == owner {
      invokeCallback(callback, owner: owner, arguments: [response])
    }
  }

  private func invokeCallback(_ callback: JSValue, owner: Int, arguments: [Any]) {
    guard active?.id == owner else { return }
    runtime.context.exception = nil
    callback.call(withArguments: arguments)
    // The callback can finish its own request. Never complete a different owner.
    if active?.id == owner, let exception = runtime.context.exception {
      complete(.failure(WorkspaceError(message: exception.toString(), violations: [])))
    }
  }
  private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
  }
}

/// SQLite transactions can span MainActor turns. All windows opening one physical
/// file share admission, while independent files and in-memory samples stay separate.
@MainActor
private final class WorkspaceFileGate {
  private struct Identity: Hashable {
    let device: UInt64
    let inode: UInt64
  }
  private struct WeakGate {
    weak var value: WorkspaceFileGate?
  }
  private static var files: [Identity: WeakGate] = [:]
  private var owner: NativeWorkspace?
  private var waiting: [NativeWorkspace] = []

  let path: String

  private init(path: String) { self.path = path }

  static func open(_ path: String) throws -> (gate: WorkspaceFileGate, database: SQLiteBridge) {
    if path.isEmpty || path == ":memory:" {
      return (
        WorkspaceFileGate(path: path), try SQLiteBridge(path: path, deferredPreparation: true)
      )
    }
    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if FileManager.default.fileExists(atPath: canonical),
      let existing = files[try identity(canonical)]?.value
    {
      // Keep the opened filename stable for SQLite and its journal.
      guard try identity(existing.path) == identity(canonical) else {
        throw WorkspaceError(
          message: "The workspace file moved or changed. Close its other windows and reopen it.",
          violations: [])
      }
      return (existing, try SQLiteBridge(path: existing.path, deferredPreparation: true))
    }
    let database = try SQLiteBridge(path: canonical, deferredPreparation: true)
    let key = try identity(canonical)
    files = files.filter { $0.value.value != nil }
    let gate = WorkspaceFileGate(path: canonical)
    files[key] = WeakGate(value: gate)
    return (gate, database)
  }

  private static func identity(_ path: String) throws -> Identity {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
      throw WorkspaceError(
        message:
          "Hard-linked databases cannot be opened safely. Open a regular database file instead.",
        violations: [])
    }
    guard let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber
    else {
      throw WorkspaceError(message: "Could not identify the workspace file.", violations: [])
    }
    return Identity(device: device.uint64Value, inode: inode.uint64Value)
  }

  func acquire(_ workspace: NativeWorkspace) -> Bool {
    if owner === workspace { return true }
    guard owner == nil else {
      if !waiting.contains(where: { $0 === workspace }) { waiting.append(workspace) }
      return false
    }
    owner = workspace
    return true
  }

  func release(_ workspace: NativeWorkspace) {
    precondition(owner === workspace)
    // Reserve the next owner now, so a just-completed instance cannot jump ahead.
    owner = waiting.isEmpty ? nil : waiting.removeFirst()
    if let next = owner {
      Task { @MainActor in next.startNext() }
    }
  }
}
