import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IrisKit

struct RetainedFilesTests {
  @Test func editorPreviewUsesABoundedStaticRasterAndPreservesOriginalBytes() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 2048, height: 2,
        bitsPerComponent: 8, bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
    let file = try RetainedFile(data: data as Data, contentType: "image/png", name: "wide.png")
    defer { file.dispose() }
    let preview = try await file.imagePreview()
    let decoded = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 1024 && image.height == 1)
    #expect(CGImageSourceGetCount(decoded) == 1)
    #expect(try Data(contentsOf: file.url) == (data as Data))
    let unsafe = try RetainedFile(
      data: Data("<svg/>".utf8), contentType: "image/svg+xml", name: "unsafe.svg")
    defer { unsafe.dispose() }
    await #expect(throws: Error.self) { try await unsafe.imagePreview() }
  }

  @Test func previewDownloadEnforcesItsSmallerByteLimit() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RetainedFileHTTPFixture.self]
    let hub = try HubTransport(
      endpoint: "https://hub.example/base", token: "fixture-token", configuration: config)
    await #expect(throws: Error.self) {
      try await hub.retainedFile(key: "raw/diagram one.png", maximumBytes: 4)
    }
  }

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
