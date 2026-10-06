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
    case .number(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .null: ""
    default: String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
  }
  public var isTrue: Bool { self == .bool(true) || self == .number(1) }
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
}

/// One request owns the database until its promise settles or awaits HTTP outside a transaction.
/// MainActor alone is insufficient: it is reentrant at each awaited SQL call.
@MainActor
public final class NativeWorkspace {
  private let runtime: LifeCoreRuntime
  private let database: SQLiteBridge
  private let path: String
  private var syncLock: SyncFileLock?
  private enum Work {
    case request(Request)
    case resumeTransport(Int, JSValue, String)
  }
  private var requests: [Work] = []
  private var active: Request?
  private var suspended: [Int: Request] = [:]
  private var nextID = 0
  private var closed = false

  private struct Request {
    let id: Int
    let method: String
    let arguments: String
    let transport: HubTransport?
    let continuation: CheckedContinuation<JSONValue, Error>
    let control: SyncControl?
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
    init(timeout: Duration, onProgress: ((WorkspaceSyncProgress) -> Void)?) {
      self.timeout = timeout
      self.onProgress = onProgress
    }
    func report(_ phase: String) {
      self.phase = phase
      onProgress?(
        WorkspaceSyncProgress(
          phase: phase, table: table, page: page,
          processedRows: processedRows, startedAt: startedAt))
    }
  }
  private struct Reply: Decodable {
    let value: JSONValue?
    let error: String?
    let violations: [Violation]?
  }

  public convenience init(path: String) throws {
    try self.init(path: path, runtime: LifeCoreRuntime())
  }

  init(path: String, runtime: LifeCoreRuntime) throws {
    guard
      runtime.context.objectForKeyedSubscript("LifeNative")?.forProperty("contractHash")?.toString()
        == CoreContract.hash
    else {
      throw WorkspaceError(
        message: "Core contract does not match the bundled runtime.", violations: [])
    }
    self.path = path
    self.runtime = runtime
    database = try SQLiteBridge(path: path)
    try database.install(in: runtime.context)
    let finish: @convention(block) (Int, String) -> Void = { [weak self] id, json in
      self?.finish(id: id, json: json)
    }
    let yield: @convention(block) (JSValue) -> Void = { callback in
      Task { @MainActor in
        await Task.yield()
        callback.call(withArguments: [])
      }
    }
    let post: @convention(block) (String, String, JSValue) -> Void = {
      [weak self] route, json, callback in
      guard let self, let owner = self.active, let transport = owner.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
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
            let table = body["table"]?.text
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
    }
    runtime.context.setObject(post, forKeyedSubscript: "__lifePost" as NSString)
    let get: @convention(block) (String, JSValue) -> Void = { [weak self] route, callback in
      guard let self, let owner = self.active, let transport = owner.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
        return
      }
      do { try self.suspendForTransport(owner) } catch {
        callback.call(withArguments: [
          #"{"error":"Network request attempted inside a transaction."}"#
        ])
        return
      }
      Task { @MainActor in
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
    runtime.context.setObject(get, forKeyedSubscript: "__lifeGet" as NSString)
    runtime.context.setObject(finish, forKeyedSubscript: "__lifeFinish" as NSString)
    runtime.context.setObject(yield, forKeyedSubscript: "__lifeYield" as NSString)
  }

  public func catalog() async throws -> WorkspaceCatalog {
    try await WorkspaceCatalog(decode(CoreRequests.Catalog(CoreEmptyArgs())))
  }
  public func writeability(table: String) async throws -> CoreWriteability {
    try await decode(CoreRequests.Writeability(CoreWriteabilityArgs(table: table)))
  }
  public func rows(view: CoreView) async throws -> [WorkspaceRow] {
    try await decode(CoreRequests.Rows(view))
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
    try await decode(CoreRequests.ReferencedBy(args))
  }
  public func search(_ args: CoreSearchArgs) async throws -> [CoreSearchHit] {
    try await decode(CoreRequests.Search(args))
  }
  public func listViews(table: String) async throws -> CoreSavedViewList {
    try await decode(CoreRequests.ListViews(CoreListViewsArgs(table: table)))
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
  public func close() async throws { _ = try await call("close") }

  private func decode<R: CoreRequest>(
    _ request: R, transport: HubTransport? = nil, control: SyncControl? = nil
  ) async throws
    -> R.Response
  {
    let arguments = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
    let value = try await call(
      R.method, arguments: arguments, transport: transport, control: control)
    return try JSONDecoder().decode(R.Response.self, from: JSONEncoder().encode(value))
  }
  private func call(
    _ method: String, arguments: String = "{}", transport: HubTransport? = nil,
    control: SyncControl? = nil
  ) async throws -> JSONValue {
    guard !closed else { throw WorkspaceError(message: "Workspace is closed.", violations: []) }
    return try await withCheckedThrowingContinuation { continuation in
      nextID += 1
      requests.append(
        .request(
          Request(
            id: nextID, method: method, arguments: arguments, transport: transport,
            continuation: continuation, control: control)))
      startNext()
    }
  }
  private func startNext() {
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
    if case .resumeTransport(let id, let callback, let response) = requests[index] {
      requests.remove(at: index)
      guard let owner = suspended.removeValue(forKey: id) else { return }
      active = owner
      callback.call(withArguments: [response])
      return
    }
    guard case .request(let request) = requests[index] else { return }
    // Close waits for every suspended request; a second sync waits for its owner.
    if request.method == "close", !suspended.isEmpty { return }
    requests.remove(at: index)
    active = request
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
    runtime.context.objectForKeyedSubscript("LifeNative")?.invokeMethod(
      "request", withArguments: [request.id, request.method, request.arguments])
    if let exception = runtime.context.exception {
      complete(.failure(WorkspaceError(message: exception.toString(), violations: [])))
    }
  }
  private func finish(id: Int, json: String) {
    guard active?.id == id else { return }
    do {
      let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
      if let error = reply.error {
        complete(.failure(WorkspaceError(message: error, violations: reply.violations ?? [])))
      } else {
        complete(.success(reply.value ?? .null))
      }
    } catch { complete(.failure(error)) }
  }
  private func complete(_ result: Result<JSONValue, Error>) {
    if active?.method == "sync" {
      syncLock = nil
      active?.control?.deadline?.cancel()
    }
    let continuation = active?.continuation
    active = nil
    continuation?.resume(with: result)
    // Do not reenter JSC from inside its completion callback.
    Task { @MainActor [self] in startNext() }
  }

  private func suspendForTransport(_ owner: Request) throws {
    guard suspended[owner.id] == nil, !database.isInsideTransaction else {
      throw WorkspaceError(
        message: "Network request attempted inside a transaction.", violations: [])
    }
    suspended[owner.id] = owner
    active = nil
    // Leave the current JSC callback before starting another JS operation.
    Task { @MainActor [self] in startNext() }
  }

  private func receiveTransport(owner: Int, callback: JSValue, response: String) {
    if let request = suspended[owner] {
      request.control?.network = nil
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
      callback.call(withArguments: [response])
    }
  }
}
