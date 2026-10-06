import Foundation
import Testing

@testable import LifeKit

struct RetainedFilesTests {
  @Test func keysCannotChangeTheOriginOrEscapeTheFilesRoute() throws {
    #expect(try retainedFileRoute(key: "raw/diagram one.png") == "/v1/files/raw/diagram%20one.png")
    for key in ["", "../secret", "a/../b", "/a", "a//b", "https://other.example/a", "a\\b", "a\n"] {
      #expect(throws: Error.self) { try retainedFileRoute(key: key) }
    }
  }

  @Test func authenticatedDownloadOwnsItsTemporaryFileAndSurfacesMissingBytes() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RetainedFileHTTPFixture.self]
    let hub = try HubTransport(
      endpoint: "https://hub.example/base", token: "fixture-token", configuration: config)
    let file = try await hub.retainedFile(key: "raw/diagram one.png")
    #expect(file.contentType == "image/png")
    #expect(try Data(contentsOf: file.url) == Data("fixture bytes".utf8))
    #expect(file.url.isFileURL)
    file.dispose()
    file.dispose()
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    await #expect(throws: Error.self) { try await hub.retainedFile(key: "missing") }
  }
}

private final class RetainedFileHTTPFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    #expect(request.url?.host == "hub.example")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    let found =
      request.url?.absoluteString == "https://hub.example/base/v1/files/raw/diagram%20one.png"
    let response = HTTPURLResponse(
      url: request.url!, statusCode: found ? 200 : 404, httpVersion: nil,
      headerFields: ["Content-Type": "image/png"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("fixture bytes".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
