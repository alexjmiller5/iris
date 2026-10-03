import Foundation
import Testing

@testable import LifeKit

struct EnrollmentTransportTests {
  private func hub(_ fixture: String) throws -> HubTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EnrollmentHTTPFixture.self]
    return try HubTransport(
      endpoint: "https://enrollment.invalid/\(fixture)", token: "synthetic-candidate",
      configuration: config)
  }

  @Test func sessionStatusAndCleanupStayTypedOnTheFixedEndpoint() async throws {
    let approved = try await hub("approved").sessionReply(maxResponseBytes: 1024)
    #expect(approved.status == 200)
    #expect(
      approved.data
        == .object(["name": .string("device:fixture"), "scopes": .array([.string("full")])]))
    let pending = try await hub("pending").sessionReply(maxResponseBytes: 10)
    #expect(pending == CoreSessionReply(status: 401, data: .null))
    let capped = try await hub("capped").sessionReply(maxResponseBytes: 10)
    #expect(capped == CoreSessionReply(status: 429, data: .null, retryAfterSeconds: 17))
    let redirect = try await hub("redirect").sessionReply(maxResponseBytes: 10)
    #expect(redirect.status == 302 && redirect.data == .null)
    let revoked = try await hub("revoke").sessionReply(revoking: true, maxResponseBytes: 1024)
    #expect(revoked.data == .object(["logged_out": .bool(true)]))
  }

  @Test(arguments: ["advertised-large", "stream-large", "invalid-json", "html", "network"])
  func unsafeRepliesFailWithoutLeakingCredentialsOrBodies(fixture: String) async throws {
    do {
      _ = try await hub(fixture).sessionReply(maxResponseBytes: 32)
      Issue.record("Accepted \(fixture)")
    } catch {
      #expect(!error.localizedDescription.contains("synthetic-candidate"))
      #expect(!error.localizedDescription.contains("PRIVATE-RESPONSE"))
      #expect(!error.localizedDescription.contains("enrollment.invalid"))
    }
  }

  @Test func cancellationRemainsCancellation() async throws {
    let transport = try hub("approved")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await transport.sessionReply(maxResponseBytes: 1024)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func cancellingAnInFlightSessionRequestPreservesCancellationIdentity() async throws {
    let transport = try hub("held")
    let task = Task { try await transport.sessionReply(maxResponseBytes: 1024) }
    for _ in 0..<500 {
      if EnrollmentHTTPFixture.started.value { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(EnrollmentHTTPFixture.started.value)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

private final class EnrollmentHTTPFixture: URLProtocol, @unchecked Sendable {
  static let started = SessionStarted()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let fixture = request.url!.pathComponents[1]
    guard request.url?.host == "enrollment.invalid",
      request.url?.path == "/\(fixture)/v1/session",
      request.url?.query == nil,
      request.httpMethod == (fixture == "revoke" ? "POST" : "GET"),
      request.httpBody == nil, request.httpBodyStream == nil,
      request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-candidate",
      request.value(forHTTPHeaderField: "Cookie") == nil
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if fixture == "network" {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    if fixture == "held" {
      Self.started.mark()
      return
    }
    var status = 200
    var headers = ["Content-Type": "application/json"]
    var body = #"{"name":"device:fixture","scopes":["full"]}"#
    switch fixture {
    case "pending":
      status = 401
      body = "PRIVATE-RESPONSE"
    case "capped":
      status = 429
      headers["Retry-After"] = "17"
      body = "PRIVATE-RESPONSE"
    case "redirect":
      status = 302
      headers["Location"] = "https://other.invalid/token"
      body = ""
    case "revoke": body = #"{"logged_out":true}"#
    case "advertised-large": headers["Content-Length"] = "1000000"
    case "stream-large": body = String(repeating: " ", count: 33) + "{}"
    case "invalid-json": body = "PRIVATE-RESPONSE"
    case "html":
      headers["Content-Type"] = "text/html"
      body = "PRIVATE-RESPONSE"
    default: break
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class SessionStarted: @unchecked Sendable {
  private let lock = NSLock()
  private var didStart = false
  var value: Bool { lock.withLock { didStart } }
  func mark() { lock.withLock { didStart = true } }
}
