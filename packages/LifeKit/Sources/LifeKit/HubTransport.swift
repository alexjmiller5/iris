import Darwin
import Foundation

struct HubReply: Codable, Sendable {
  let data: JSONValue
  let date: String?
}

/// No cookies, credential cache, redirects, or URL/token details in failures.
struct HubTransport: Sendable {
  let endpoint: String
  private let token: String
  private let session: URLSession

  init(endpoint: String, token: String, configuration: URLSessionConfiguration = .ephemeral) throws
  {
    guard endpoint.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      !endpoint.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\\" }),
      var parts = URLComponents(string: endpoint), let host = parts.host?.lowercased(),
      !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.scheme?.lowercased() == "https"
        || (parts.scheme?.lowercased() == "http"
          && (host == "localhost" || host == "[::1]" || host == "::1"
            || host.range(of: #"^127(?:\.[0-9]{1,3}){3}$"#, options: .regularExpression) != nil)),
      !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) })
    else {
      throw WorkspaceError(
        message:
          "Enter an HTTPS hub URL and a valid scoped token. HTTP is allowed only on loopback.",
        violations: [])
    }
    parts.scheme = parts.scheme?.lowercased()
    parts.host = host
    guard let url = parts.url else {
      throw WorkspaceError(message: "Invalid hub URL.", violations: [])
    }
    self.endpoint = url.absoluteString.replacingOccurrences(
      of: #"/+$"#, with: "", options: .regularExpression)
    self.token = token
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    session = URLSession(
      configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }

  func get(route: String) async throws -> HubReply {
    try await request(route: route, body: nil)
  }

  func post(route: String, body: WorkspaceRecord) async throws -> HubReply {
    try await request(route: route, body: body)
  }

  private func request(route: String, body: WorkspaceRecord?) async throws -> HubReply {
    let pattern =
      body == nil
      ? #"^/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*(?:\?[A-Za-z0-9_=&.%~-]+)?$"#
      : #"^/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$"#
    guard
      route.range(of: pattern, options: .regularExpression) != nil,
      !route.contains(where: { $0.isWhitespace }), let url = URL(string: endpoint + route)
    else { throw WorkspaceError(message: "Invalid hub route.", violations: []) }
    var request = URLRequest(url: url)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) } catch {
      throw WorkspaceError(
        message: "Hub request failed. Check the connection and try again.", violations: [])
    }
    guard let response = response as? HTTPURLResponse else {
      throw WorkspaceError(message: "Invalid hub response.", violations: [])
    }
    guard (200..<300).contains(response.statusCode) else {
      throw WorkspaceError(message: "Hub HTTP \(response.statusCode).", violations: [])
    }
    let contentType = response.mimeType?.lowercased() ?? ""
    guard
      contentType == "application/json"
        || (contentType.hasPrefix("application/") && contentType.hasSuffix("+json")),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { throw WorkspaceError(message: "Hub response is not valid JSON.", violations: []) }
    return HubReply(data: value, date: response.value(forHTTPHeaderField: "Date"))
  }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Compatible with Python fcntl.flock on <database>.sync.lock.
final class SyncFileLock {
  private let descriptor: Int32
  init(databasePath: String) throws {
    let opened = Darwin.open(
      databasePath + ".sync.lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard opened >= 0 else {
      throw WorkspaceError(message: "Cannot open the workspace sync lock.", violations: [])
    }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(opened)
      throw WorkspaceError(
        message: "Another client is syncing this workspace. Try again when it finishes.",
        violations: [])
    }
    descriptor = opened
  }
  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}
