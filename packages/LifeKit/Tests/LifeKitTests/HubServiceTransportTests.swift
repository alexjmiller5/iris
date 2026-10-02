import Foundation
import Testing

@testable import LifeKit

struct HubServiceTransportTests {
  @Test func getPreservesPaginationAndScopedAuthWithoutSendingABody() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ServiceGetFixture.self]
    let hub = try HubTransport(
      endpoint: "https://service.invalid/prefix", token: "fixture", configuration: config)
    let reply = try await hub.get(route: "/v1/notifications?after=7&limit=100")
    #expect(reply.data == .object(["ok": .bool(true)]))
    #expect(reply.date == "Fri, 02 Oct 2026 15:00:00 GMT")
    for route in [
      "//other.invalid", "/../secret", "/v1/%2fsecret", "/v1/usage#fragment",
      "/v1/usage?x=hello world", "https://other.invalid/v1/usage",
    ] {
      await #expect(throws: Error.self) { try await hub.get(route: route) }
    }
  }
}

private final class ServiceGetFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "service.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
      request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
      request.value(forHTTPHeaderField: "Accept") == "application/json",
      request.url?.absoluteString
        == "https://service.invalid/prefix/v1/notifications?after=7&limit=100"
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json", "Date": "Fri, 02 Oct 2026 15:00:00 GMT"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
