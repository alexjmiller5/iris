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
public struct WorkspaceCatalog: Sendable {
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
}
public struct WorkspaceError: Error, LocalizedError, Sendable {
  public let message: String
  public let violations: [Violation]
  public var errorDescription: String? { message }
}

/// One request owns the database until its JavaScript promise settles.
/// MainActor alone is insufficient: it is reentrant at each awaited SQL call.
@MainActor
public final class NativeWorkspace {
  private let runtime: LifeCoreRuntime
  private let database: SQLiteBridge
  private let path: String
  private var syncLock: SyncFileLock?
  private var requests: [Request] = []
  private var active: Request?
  private var nextID = 0
  private var closed = false

  private struct Request {
    let id: Int
    let method: String
    let arguments: String
    let transport: HubTransport?
    let continuation: CheckedContinuation<JSONValue, Error>
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
      guard let transport = self?.active?.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
        return
      }
      Task { @MainActor in
        let response: String
        do {
          let body = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))
          let reply = try await transport.post(route: route, body: body)
          response = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        } catch {
          response = String(
            decoding: try! JSONEncoder().encode(["error": error.localizedDescription]),
            as: UTF8.self)
        }
        callback.call(withArguments: [response])
      }
    }
    runtime.context.setObject(post, forKeyedSubscript: "__lifePost" as NSString)
    let get: @convention(block) (String, JSValue) -> Void = { [weak self] route, callback in
      guard let transport = self?.active?.transport else {
        callback.call(withArguments: [#"{"error":"No hub connection."}"#])
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
        callback.call(withArguments: [response])
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
  public func status() async throws -> WorkspaceSyncStatus {
    try await decode(CoreRequests.Status(CoreEmptyArgs()))
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

  func sync(using transport: HubTransport, maxRows: Int? = nil, tables: [String: Bool]? = nil)
    async throws
    -> WorkspaceSyncResult
  {
    try await decode(
      CoreRequests.Sync(
        CoreSyncArgs(endpoint: transport.endpoint, maxRows: maxRows, tables: tables)),
      transport: transport)
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

  private func decode<R: CoreRequest>(_ request: R, transport: HubTransport? = nil) async throws
    -> R.Response
  {
    let arguments = String(decoding: try JSONEncoder().encode(request.arguments), as: UTF8.self)
    let value = try await call(R.method, arguments: arguments, transport: transport)
    return try JSONDecoder().decode(R.Response.self, from: JSONEncoder().encode(value))
  }
  private func call(
    _ method: String, arguments: String = "{}", transport: HubTransport? = nil
  ) async throws -> JSONValue {
    guard !closed else { throw WorkspaceError(message: "Workspace is closed.", violations: []) }
    return try await withCheckedThrowingContinuation { continuation in
      nextID += 1
      requests.append(
        Request(
          id: nextID, method: method, arguments: arguments, transport: transport,
          continuation: continuation))
      startNext()
    }
  }
  private func startNext() {
    guard active == nil, !requests.isEmpty else { return }
    let request = requests.removeFirst()
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
    syncLock = nil
    let continuation = active?.continuation
    active = nil
    continuation?.resume(with: result)
    // Do not reenter JSC from inside its completion callback.
    Task { @MainActor [self] in startNext() }
  }
}
