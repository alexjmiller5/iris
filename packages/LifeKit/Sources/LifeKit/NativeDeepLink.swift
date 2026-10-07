import Foundation

enum NativeWorkspaceBinding: Equatable, Sendable {
  case replica(String)
  case local(UUID)

  /// Supply the installed transport's canonical endpoint, never draft credentials.
  static func replica(canonicalEndpoint: String) -> Self {
    .replica(WorkspaceModel.replicaKey(endpoint: canonicalEndpoint))
  }
}

struct NativeDeepLink: Equatable, Sendable {
  let binding: NativeWorkspaceBinding
  let destination: NativeDestination

  init(destination: NativeDestination, workspace: NativeWorkspaceBinding?) throws {
    guard let workspace else {
      throw WorkspaceError(message: "This workspace cannot create a persistent link.", violations: [])
    }
    guard !destination.table.isEmpty, destination.viewID?.isEmpty != true,
      destination.rowID?.isEmpty != true
    else { throw Self.invalid }
    if case .replica(let digest) = workspace {
      guard digest.utf8.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw Self.invalid }
    }
    if let state = destination.state { _ = try Self.viewState(state) }
    binding = workspace
    self.destination = destination
  }

  init(url: URL) throws {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "life", parts.host?.lowercased() == "open",
      parts.path == "/v1", parts.user == nil, parts.password == nil,
      parts.port == nil, parts.fragment == nil, let items = parts.queryItems
    else { throw Self.invalid }
    let allowed: Set<String> = ["replica", "local", "table", "view", "row", "state"]
    var values: [String: String] = [:]
    for item in items {
      guard allowed.contains(item.name), values[item.name] == nil,
        let value = item.value, !value.isEmpty
      else { throw Self.invalid }
      values[item.name] = value
    }
    guard (values["replica"] == nil) != (values["local"] == nil),
      let table = values["table"]
    else { throw Self.invalid }
    let workspace: NativeWorkspaceBinding
    if let digest = values["replica"] {
      workspace = .replica(digest)
    } else {
      guard let text = values["local"], let id = UUID(uuidString: text) else { throw Self.invalid }
      workspace = .local(id)
    }
    try self.init(
      destination: NativeDestination(table: table, viewID: values["view"], rowID: values["row"], state: values["state"]),
      workspace: workspace)
  }

  var url: URL {
    var parts = URLComponents()
    parts.scheme = "life"
    parts.host = "open"
    parts.path = "/v1"
    var items: [URLQueryItem]
    switch binding {
    case .replica(let digest): items = [URLQueryItem(name: "replica", value: digest)]
    case .local(let id): items = [URLQueryItem(name: "local", value: id.uuidString.lowercased())]
    }
    items.append(URLQueryItem(name: "table", value: destination.table))
    if let view = destination.viewID { items.append(URLQueryItem(name: "view", value: view)) }
    if let row = destination.rowID { items.append(URLQueryItem(name: "row", value: row)) }
    if let state = destination.state { items.append(URLQueryItem(name: "state", value: state)) }
    parts.queryItems = items
    // The constructor validates structure; URLComponents escapes all opaque values.
    return parts.url!
  }

  func destination(matching workspace: NativeWorkspaceBinding?) throws -> NativeDestination {
    guard workspace == binding else {
      throw WorkspaceError(message: "Open the workspace that this link belongs to.", violations: [])
    }
    return destination
  }

  static func viewState(_ text: String) throws -> WorkspaceRecord {
    guard text.utf8.count <= 16_384,
      case .object(let value) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
      value["actions"] == nil else { throw invalid }
    return value
  }

  private static var invalid: WorkspaceError {
    WorkspaceError(message: "This Life link is invalid or uses an unsupported version.", violations: [])
  }
}
