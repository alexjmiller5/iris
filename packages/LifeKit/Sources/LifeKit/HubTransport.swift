import Darwin
import Foundation

struct HubReply: Codable, Sendable {
  let data: JSONValue
  let date: String?
}

/// No cookies, credential cache, redirects, or URL/token details in failures.
struct HubTransport: Sendable {
  /// Every connection-level failure uses this text; the sync pill reads it as offline.
  static let unreachableMessage = "Hub request failed. Check the connection and try again."
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
    configuration.httpAdditionalHeaders = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    session = URLSession(
      configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }

  var imageRequestIdentity: ObjectIdentifier { ObjectIdentifier(session) }

  /// Binary previews stay on the supported file route and bypass the SQL queue.
  func imageData(key: String, maxBytes: Int) async throws -> Data {
    var request = URLRequest(url: try ImageReference.retained(key).url(endpoint: endpoint))
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    return try await ImagePreviewLoader.read(request: request, session: session, maxBytes: maxBytes)
  }

  func get(route: String) async throws -> HubReply {
    try await request(route: route, body: nil)
  }

  func post(route: String, body: WorkspaceRecord) async throws -> HubReply {
    try await request(route: route, body: body)
  }

  func uploadAttachment(_ entry: StagedAttachment, file: URL) async throws -> AttachmentReceipt {
    try await AttachmentUploader(endpoint: endpoint, token: token, session: session).upload(
      entry, file: file)
  }

  func retainedFile(key: String, maximumBytes: Int = 128 * 1024 * 1024) async throws -> RetainedFile
  {
    let route = try retainedFileRoute(key: key)
    guard maximumBytes > 0, maximumBytes <= 128 * 1024 * 1024,
      let url = URL(string: endpoint + route)
    else {
      throw WorkspaceError(message: "Invalid file request.", violations: [])
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      let (bytes, reply) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let reply = reply as? HTTPURLResponse else {
        throw WorkspaceError(message: "Invalid file response.", violations: [])
      }
      guard (200..<300).contains(reply.statusCode) else {
        throw WorkspaceError(
          message:
            "File HTTP \(reply.statusCode). Retry after checking your connection and access.",
          violations: [])
      }
      guard reply.expectedContentLength <= maximumBytes else {
        throw WorkspaceError(message: "File exceeds the viewing size limit.", violations: [])
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < maximumBytes else {
          throw WorkspaceError(message: "File exceeds the viewing size limit.", violations: [])
        }
        data.append(byte)
      }
      return try RetainedFile(
        data: data, contentType: reply.mimeType?.lowercased() ?? "application/octet-stream",
        name: key.split(separator: "/").last.map(String.init) ?? "attachment")
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let failure = error as? WorkspaceError { throw failure }
      throw WorkspaceError(
        message: "File request failed. Check the connection and retry.", violations: [])
    }
  }

  /// Enrollment keeps HTTP status separate from policy. Only the fixed session
  /// endpoint receives the candidate credential; large sync replies use their own path.
  func sessionReply(revoking: Bool = false, maxResponseBytes: Int) async throws -> CoreSessionReply
  {
    try await boundedReply(
      route: "/v1/session", method: revoking ? "POST" : "GET", body: nil,
      maxResponseBytes: maxResponseBytes, decodeStatuses: [200])
  }

  @MainActor func pushApprovalURL(profile: String) async throws -> URL {
    let core = try EnrollmentCore()
    let approval = try await core.request(
      CoreRequests.EnrollmentApproval(
        CoreEnrollmentApprovalArgs(
          fingerprint: DeviceCandidate(token: token).fingerprint, name: "Life UI")))
    guard var parts = URLComponents(string: endpoint + approval.path) else {
      throw URLError(.badURL)
    }
    parts.queryItems =
      (parts.queryItems ?? []) + [URLQueryItem(name: "pushProfile", value: profile)]
    guard let url = parts.url else { throw URLError(.badURL) }
    return url
  }

  @MainActor func pushRegistration(_ operation: PushRegistration.Operation) async throws
    -> PushRegistration.Reply
  {
    let route: String
    let body: Data?
    switch operation {
    case .read(let profile):
      guard !profile.isEmpty, profile.utf8.count <= 512,
        let query = profile.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
      else { throw WorkspaceError(message: "Invalid push profile.", violations: []) }
      route = "/v1/push/registration?appProfile=" + query
      body = nil
    case .register(let request):
      route = "/v1/push/registration"
      body = try JSONEncoder().encode(request)
    case .revoke(let request):
      route = "/v1/push/registration/revoke"
      body = try JSONEncoder().encode(request)
    }
    let reply = try await boundedReply(
      route: route, method: body == nil ? "GET" : "POST", body: body,
      maxResponseBytes: 65536, decodeStatuses: [200, 409])
    guard case .object(let object) = reply.data else {
      throw WorkspaceError(message: "Push registration was not confirmed.", violations: [])
    }
    if reply.status == 409, object["kind"] == .string("conflict"),
      object["code"] == .string("registration_changed")
    {
      return .conflict
    }
    if reply.status == 200, object["kind"] == .string("unavailable") { return .unavailable }
    if reply.status == 200, object["kind"] == .string("available"), case .read = operation,
      let state = object["registration"]
    {
      if state == .null { return .baseline(nil) }
      return .baseline(
        try JSONDecoder().decode(CorePushRegistrationState.self, from: JSONEncoder().encode(state)))
    }
    if reply.status == 200, object["kind"] == .string("confirmed"), let receipt = object["receipt"]
    {
      return .confirmed(
        try JSONDecoder().decode(
          CorePushRegistrationReceipt.self, from: JSONEncoder().encode(receipt)))
    }
    throw WorkspaceError(message: "Invalid push registration response.", violations: [])
  }

  private func boundedReply(
    route: String, method: String, body: Data?, maxResponseBytes: Int,
    decodeStatuses: Set<Int>
  ) async throws -> CoreSessionReply {
    try Task.checkCancellation()
    guard maxResponseBytes > 0, let url = URL(string: endpoint + route) else {
      throw WorkspaceError(message: "Invalid session request.", violations: [])
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let response = response as? HTTPURLResponse else {
        throw WorkspaceError(message: "Invalid session response.", violations: [])
      }
      let retry = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
      guard decodeStatuses.contains(response.statusCode) else {
        return CoreSessionReply(status: response.statusCode, data: .null, retryAfterSeconds: retry)
      }
      let mime = response.mimeType?.lowercased() ?? ""
      guard
        mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")),
        response.expectedContentLength <= maxResponseBytes
      else {
        throw WorkspaceError(message: "Invalid or oversized session response.", violations: [])
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < maxResponseBytes else {
          throw WorkspaceError(message: "Session response is too large.", violations: [])
        }
        data.append(byte)
      }
      guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        throw WorkspaceError(message: "Session response is not valid JSON.", violations: [])
      }
      return CoreSessionReply(status: response.statusCode, data: json, retryAfterSeconds: retry)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let failure = error as? WorkspaceError { throw failure }
      throw WorkspaceError(
        message: "Session request failed. Check the connection and try again.", violations: [])
    }
  }

  private static func retryAfter(_ value: String?, now: Date) -> Int? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
      let seconds = Int(trimmed), seconds <= 9_007_199_254_740_991
    {
      return seconds
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: trimmed) else { return nil }
    return max(0, Int(ceil(date.timeIntervalSince(now))))
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
      throw WorkspaceError(message: Self.unreachableMessage, violations: [])
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

final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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
