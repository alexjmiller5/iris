import Foundation
import JavaScriptCore

public enum JSONValue: Codable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
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
public typealias WorkspaceRecord = [String: JSONValue]
public struct WorkspaceCatalog: Decodable, Sendable {
  public let tables: [WorkspaceRecord]
  public let properties: [WorkspaceRecord]
  public let rules: [WorkspaceRecord]
}
public struct WorkspaceRow: Decodable, Identifiable, Sendable {
  public let record: WorkspaceRecord
  public let label: String
  public var id: String { record["id"]?.text ?? "" }
}
public struct WorkspaceError: Error, LocalizedError, Sendable {
  public let message: String
  public let violations: [Violation]
  public var errorDescription: String? { message }
}

public struct WorkspaceSyncStatus: Decodable, Sendable {
  public let lastSuccessfulSync: String?
  public let pendingUiEdits: Int
  public let rejected: Int
}

public struct WorkspaceSyncResult: Decodable, Sendable {
  public let pulled: Int
  public let pushed: Int
  public let skipped: [String]
  public let rejected: [WorkspaceRecord]
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

  public init(path: String) throws {
    self.path = path
    runtime = try LifeCoreRuntime()
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
    try await decode("catalog")
  }
  public func rows(table: String, search: String = "", trash: Bool = false, offset: Int = 0)
    async throws -> [WorkspaceRow]
  {
    try await decode(
      "rows",
      arguments: [
        "table": .string(table), "search": .string(search),
        "trash": .bool(trash), "offset": .number(Double(offset)), "limit": .number(100),
      ])
  }
  public func write(table: String, patch: WorkspaceRecord, expectedUpdatedAt: String? = nil)
    async throws -> WorkspaceRecord
  {
    var arguments: WorkspaceRecord = ["table": .string(table), "patch": .object(patch)]
    if let expectedUpdatedAt { arguments["expectedUpdatedAt"] = .string(expectedUpdatedAt) }
    return try await decode("write", arguments: arguments)
  }
  public func status() async throws -> WorkspaceSyncStatus { try await decode("status") }

  func usage(using transport: HubTransport) async throws -> UsageSummary {
    try await decode(
      "serviceUsage", arguments: ["endpoint": .string(transport.endpoint)], transport: transport)
  }
  func notifications(using transport: HubTransport) async throws -> NotificationFeed {
    try await decode(
      "serviceNotifications", arguments: ["endpoint": .string(transport.endpoint)],
      transport: transport)
  }
  func markNotificationsRead(using transport: HubTransport, selector: WorkspaceRecord) async throws
    -> NotificationReadResult
  {
    try await decode(
      "markNotificationsRead",
      arguments: ["endpoint": .string(transport.endpoint), "selector": .object(selector)],
      transport: transport)
  }
  func notificationPresentation(_ feed: NotificationFeed, baseline: Int?) async throws
    -> NotificationPresentation
  {
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(feed))
    return try await decode(
      "notificationPresentation",
      arguments: ["feed": value, "baseline": baseline.map { .number(Double($0)) } ?? .null])
  }

  func sync(using transport: HubTransport) async throws -> WorkspaceSyncResult {
    let value = try await call(
      "sync", arguments: ["endpoint": .string(transport.endpoint)], transport: transport)
    return try JSONDecoder().decode(WorkspaceSyncResult.self, from: JSONEncoder().encode(value))
  }
  public func createSample() async throws { _ = try await call("sample") }
  public func close() async throws { _ = try await call("close") }

  private func decode<T: Decodable>(
    _ method: String, arguments: WorkspaceRecord = [:], transport: HubTransport? = nil
  ) async throws
    -> T
  {
    let value = try await call(method, arguments: arguments, transport: transport)
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  }
  private func call(
    _ method: String, arguments: WorkspaceRecord = [:], transport: HubTransport? = nil
  ) async throws -> JSONValue {
    guard !closed else { throw WorkspaceError(message: "Workspace is closed.", violations: []) }
    let json = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      nextID += 1
      requests.append(
        Request(
          id: nextID, method: method, arguments: json, transport: transport,
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
