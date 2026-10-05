import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import LifeKit

struct ImagePreviewTests {
  private func config() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [ImageHTTPFixture.self]
    c.httpAdditionalHeaders = ["Authorization": "must-not-leak", "Cookie": "must-not-leak"]
    return c
  }
  @Test func recognizesValuesWithoutColumnNames() {
    #expect(
      ImageReference.previews(type: "url", value: "https://cdn.invalid/a.JPG?size=40").count == 1)
    #expect(ImageReference.previews(type: "text", value: "photos/a.png").count == 1)
    #expect(ImageReference.previews(type: "text", value: "/v1/files/photos/a.png").count == 1)
    #expect(
      ImageReference.previews(
        type: "json", value: #"["photos/a.png",42,"https://cdn.invalid/b.webp","docs/a.pdf"]"#
      ).count == 2)
    for value in [
      "https://cdn.invalid/path?file=a.png", "a.png", "photos/../a.png", "photos/a%2fb.png",
      "http://cdn.invalid/a.png",
    ] {
      #expect(ImageReference.previews(type: "text", value: value).isEmpty)
    }
    #expect(ImageReference.previews(type: "markdown", value: "photos/a.png").isEmpty)
  }
  @Test func embeddedImageBoundsAndSVGIsolation() throws {
    let svg =
      #"<svg xmlns="http://www.w3.org/2000/svg"><script>PRIVATE</script><image href="https://outside.invalid/a.png"/></svg>"#
    let base64 = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    let encoded =
      "data:image/svg+xml," + svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    for value in [base64, encoded] {
      let reference = try #require(ImageReference.previews(type: "text", value: value).first)
      let data = try #require(reference.embeddedSVG)
      #expect(data == Data(svg.utf8))
      let html = NativeSVGPreview.document(data)
      #expect(html.contains("img-src data:"))
      #expect(html.contains("default-src 'none'"))
      #expect(!html.contains("<svg"))
      #expect(!html.contains("PRIVATE"))
      #expect(!html.contains("outside.invalid"))
    }
    #expect(ImageReference.previews(type: "text", value: "data:text/html;base64,PHN2Zy8+").isEmpty)
    #expect(
      ImageReference.previews(
        type: "text", value: "data:image/svg+xml;base64," + String(repeating: "A", count: 1_500_000)
      ).isEmpty)
    #expect(
      ImageReference.previews(
        type: "text", value: "data:image/png;base64," + ImageHTTPFixture.png().base64EncodedString()
      ).count == 1)
  }
  @Test @MainActor func svgConfigurationIsInert() {
    let config = NativeSVGPreview.configuration()
    #expect(!config.defaultWebpagePreferences.allowsContentJavaScript)
    #expect(!config.websiteDataStore.isPersistent)
    #expect(config.userContentController.userScripts.isEmpty)
  }
  @Test func keyValidation() throws {
    #expect(
      try ImageReference.retained("images/a b.png").url(endpoint: "https://hub.invalid/base")
        .absoluteString == "https://hub.invalid/base/v1/files/images/a%20b.png")
    for key in ["", "/image.png", "a//b", "a/../b", "a/./b", "a%2fb", "a\\b", "a\nb"] {
      #expect(throws: Error.self) {
        try ImageReference.retained(key).url(endpoint: "https://hub.invalid")
      }
    }
    for value in [
      "http://external.invalid/a", "file:///tmp/a", "data:image/png;base64,AA",
      "https://user:secret@external.invalid/a", "https://external.invalid/a#part",
    ] {
      #expect(throws: Error.self) {
        try ImageReference.external(URL(string: value)!).url(endpoint: nil)
      }
    }
  }
  @Test func isolatesCredentials() async throws {
    let hub = try HubTransport(
      endpoint: "https://hub.invalid", token: "synthetic-token", configuration: config())
    let loader = ImagePreviewLoader(configuration: config())
    #expect(try await loader.load(.retained("images/valid.png"), transport: hub).width == 2)
    #expect(
      try await loader.load(
        .external(URL(string: "https://external.invalid/valid.png")!), transport: hub
      ).width == 2)
  }
  @Test(arguments: ["oversize", "stream-large", "html", "invalid", "redirect", "denied", "network"])
  func rejectsUnsafeResponses(_ fixture: String) async throws {
    do {
      _ = try await ImagePreviewLoader(configuration: config(), maxBytes: 512).load(
        .external(URL(string: "https://external.invalid/\(fixture)")!), transport: nil)
      Issue.record("Accepted unsafe image response")
    } catch {
      #expect(!error.localizedDescription.contains("PRIVATE"))
      #expect(!error.localizedDescription.contains("external.invalid"))
    }
  }
  @Test func retainedRedirectIsRefused() async throws {
    let hub = try HubTransport(
      endpoint: "https://hub.invalid", token: "synthetic-token", configuration: config())
    await #expect(throws: Error.self) {
      try await ImagePreviewLoader(configuration: config()).load(
        .retained("images/redirect.png"), transport: hub)
    }
  }
  @Test func redirectDelegateNeverAcceptsADestination() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let origin = URL(string: "https://hub.invalid/v1/files/images/a.png")!
    var redirected = URLRequest(url: URL(string: "https://outside.invalid/image.png")!)
    redirected.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
    let task = session.dataTask(with: origin)
    for status in [301, 302, 307, 308] {
      let response = HTTPURLResponse(
        url: origin, statusCode: status, httpVersion: nil,
        headerFields: ["Location": redirected.url!.absoluteString])!
      let accepted: URLRequest? = await withCheckedContinuation { continuation in
        RefuseRedirects().urlSession(
          session, task: task, willPerformHTTPRedirection: response, newRequest: redirected
        ) { continuation.resume(returning: $0) }
      }
      #expect(accepted == nil)
    }
  }
  @Test func requiresHub() async throws {
    await #expect(throws: Error.self) {
      try await ImagePreviewLoader(configuration: config()).load(
        .retained("images/valid.png"), transport: nil)
    }
  }
  @Test func cancellation() async throws {
    let loader = ImagePreviewLoader(configuration: config())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await loader.load(
        .external(URL(string: "https://external.invalid/valid.png")!), transport: nil)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
  @Test @MainActor func lateResultCannotReplaceNewImage() async throws {
    let state = ImagePreviewState()
    let first = try ImagePreviewLoader.decode(ImageHTTPFixture.png(size: 2), maxPixelSize: 64)
    let second = try ImagePreviewLoader.decode(ImageHTTPFixture.png(size: 4), maxPixelSize: 64)
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let old = Task {
      await state.load {
        started.continuation.yield(())
        for await _ in release.stream { break }
        return first
      }
    }
    for await _ in started.stream { break }
    await state.load { second }
    release.continuation.yield(())
    await old.value
    #expect(state.image?.width == 4)
    #expect(state.error == nil)
    state.invalidate()
    #expect(state.image == nil)
  }
  @Test func downsamples() throws {
    let image = try ImagePreviewLoader.decode(ImageHTTPFixture.png(size: 2000), maxPixelSize: 64)
    #expect(image.width == 64 && image.height == 64)
    #expect(throws: Error.self) {
      try ImagePreviewLoader.decode(Data("<svg/>".utf8), maxPixelSize: 64)
    }
  }
}
private final class ImageHTTPFixture: URLProtocol, @unchecked Sendable {
  static func png(size: Int = 2) -> Data {
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let retained = request.url?.host == "hub.invalid"
    guard
      request.value(forHTTPHeaderField: "Authorization")
        == (retained ? "Bearer synthetic-token" : nil),
      request.value(forHTTPHeaderField: "Cookie") == nil, request.httpMethod == "GET",
      !retained || request.url?.path.hasPrefix("/v1/files/images/") == true
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let name = request.url!.deletingPathExtension().lastPathComponent
    if name == "network" {
      client?.urlProtocol(
        self, didFailWithError: NSError(domain: "PRIVATE external.invalid", code: 1))
      return
    }
    var data = Self.png()
    var headers = ["Content-Type": "image/png"]
    if name == "oversize" { headers["Content-Length"] = "99999999" }
    if name == "stream-large" { data += Data(repeating: 0, count: 513) }
    if name == "html" { headers["Content-Type"] = "text/html" }
    if name == "invalid" { data = Data("PRIVATE invalid bytes".utf8) }
    let status = name == "redirect" ? 302 : name == "denied" ? 403 : 200
    if status == 302 { headers["Location"] = "https://external.invalid/valid.png" }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
