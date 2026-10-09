import Foundation
import Testing

@testable import IrisKit

struct PushTransportTests {
  @Test @MainActor func pushApprovalPreservesTheExistingCredentialAndEndpoint() async throws {
    let hub = try HubTransport(endpoint: "https://push-contract.invalid/prefix", token: "synthetic")
    let url = try await hub.pushApprovalURL(profile: "desktop/slash")
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(parts.host == "push-contract.invalid")
    #expect(parts.path == "/prefix/login")
    let query = Dictionary(
      uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["pushProfile"] == "desktop/slash")
    #expect(query["key"] == DeviceCandidate(token: "synthetic").fingerprint)
    #expect(!url.absoluteString.contains("synthetic"))
  }

  @Test @MainActor func preservesConflictReceiptAndUsesExistingAuthenticatedTransport() async throws
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PushTransportFixture.self]
    let hub = try HubTransport(
      endpoint: "https://push-contract.invalid/prefix", token: "synthetic",
      configuration: configuration)
    let result = try await hub.pushRegistration(
      .register(
        .init(
          appProfile: "desktop", deviceToken: "aabb", expectedRevision: nil, requestId: "request")))
    guard case .conflict = result else {
      Issue.record("Expected the exact registration conflict")
      return
    }
  }

  @Test @MainActor func refusesMalformedOrOversizedConflictBodies() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PushTransportFixture.self]
    for host in ["malformed-push.invalid", "oversized-push.invalid"] {
      let hub = try HubTransport(
        endpoint: "https://" + host, token: "synthetic", configuration: configuration)
      await #expect(throws: Error.self) {
        try await hub.pushRegistration(
          .register(
            .init(
              appProfile: "desktop", deviceToken: "aabb", expectedRevision: nil,
              requestId: "request")))
      }
    }
  }
}

private final class PushTransportFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix(".invalid") == true
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard request.httpMethod == "POST",
      request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic",
      request.value(forHTTPHeaderField: "Content-Type") == "application/json",
      request.url?.path.hasSuffix("/v1/push/registration") == true
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let body =
      request.url?.host == "oversized-push.invalid"
      ? String(repeating: " ", count: 65537)
      : request.url?.host == "malformed-push.invalid"
        ? #"{"kind":"confirmed"}"#
        : #"{"kind":"conflict","code":"registration_changed"}"#
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 409, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
