import Foundation
import ImageIO

/// Retained keys and public URLs deliberately have separate credential paths.
enum ImageReference: Hashable, Sendable {
  case retained(String)
  case external(URL)
  case embedded(mime: String, data: Data)

  private static let extensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "tif", "tiff",
  ]

  // ponytail: Extensionless images need an explicit catalog presentation contract.
  static func previews(type: String, value: String) -> [ImageReference] {
    guard ["text", "url", "json"].contains(type) else { return [] }
    let values: [String]
    if type == "json" {
      guard let array = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [Any] else {
        return []
      }
      values = array.compactMap { $0 as? String }
    } else {
      values = [value]
    }
    var seen = Set<ImageReference>()
    return values.compactMap { raw in
      let reference: ImageReference
      if raw.hasPrefix("data:") {
        guard let comma = raw.firstIndex(of: ","), raw.utf8.count <= 1_400_000 else { return nil }
        let header = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]).lowercased()
        let base64 = header.hasSuffix(";base64")
        let mime = base64 ? String(header.dropLast(7)) : header
        guard
          ["image/svg+xml", "image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
        else { return nil }
        let body = String(raw[raw.index(after: comma)...])
        let data =
          base64 ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        guard let data, !data.isEmpty, data.count <= 1_048_576 else { return nil }
        reference = .embedded(mime: mime, data: data)
        return seen.insert(reference).inserted ? reference : nil
      }
      if raw.hasPrefix("https://"), let url = URL(string: raw) {
        reference = .external(url)
      } else {
        let key = raw.hasPrefix("/v1/files/") ? String(raw.dropFirst(10)) : raw
        guard key.contains("/"), !key.contains(":") else { return nil }
        reference = .retained(key)
      }
      guard let url = try? reference.url(endpoint: "https://preview.invalid"),
        extensions.contains(url.pathExtension.lowercased()), seen.insert(reference).inserted
      else { return nil }
      return reference
    }
  }

  /// An explicitly selected Gallery cover does not need a filename extension.
  static func cover(type: String, value: String) -> ImageReference? {
    guard ["text", "url", "json"].contains(type) else { return nil }
    let values: [String]
    if type == "json" {
      values = (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    } else { values = [value] }
    for raw in values {
      let reference: ImageReference
      if raw.hasPrefix("https://"), let url = URL(string: raw) {
        reference = .external(url)
      } else if raw.hasPrefix("/v1/files/") {
        reference = .retained(String(raw.dropFirst(10)))
      } else { continue }
      if (try? reference.url(endpoint: "https://preview.invalid")) != nil { return reference }
    }
    return nil
  }

  var embeddedSVG: Data? {
    if case .embedded(let mime, let data) = self, mime == "image/svg+xml" { return data }
    return nil
  }

  func url(endpoint: String?) throws -> URL {
    switch self {
    case .embedded: throw ImagePreviewLoader.failure("Embedded images have no network address.")
    case .external(let url):
      guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
        parts.user == nil, parts.password == nil, parts.fragment == nil,
        !url.absoluteString.contains("\\")
      else { throw ImagePreviewLoader.failure("Invalid image address.") }
      return url
    case .retained(let key):
      let segments = key.split(separator: "/", omittingEmptySubsequences: false)
      guard let endpoint, !segments.isEmpty,
        !key.contains("%"), !key.contains("\\"),
        !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else { throw ImagePreviewLoader.failure("Invalid retained image reference.") }
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      let path = segments.map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }
        .joined(separator: "/")
      guard let url = URL(string: endpoint + "/v1/files/" + path) else {
        throw ImagePreviewLoader.failure("Invalid retained image reference.")
      }
      return url
    }
  }
}

final class ImagePreviewLoader: Sendable {
  private let session: URLSession
  private let maxBytes: Int
  init(configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = 8 * 1024 * 1024) {
    self.maxBytes = maxBytes
    configuration.httpAdditionalHeaders = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    session = URLSession(
      configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  func load(_ reference: ImageReference, transport: HubTransport?) async throws -> CGImage {
    try Task.checkCancellation()
    let data: Data
    switch reference {
    case .embedded(let mime, let value):
      guard mime != "image/svg+xml", value.count <= maxBytes else {
        throw Self.failure("Unsupported or oversized image.")
      }
      data = value
    case .retained(let key):
      guard let transport else { throw Self.failure("Connect to the hub to load this image.") }
      data = try await transport.imageData(key: key, maxBytes: maxBytes)
    case .external:
      var request = URLRequest(url: try reference.url(endpoint: nil))
      request.httpMethod = "GET"
      request.setValue("image/*", forHTTPHeaderField: "Accept")
      data = try await Self.read(request: request, session: session, maxBytes: maxBytes)
    }
    try Task.checkCancellation()
    let image = try await Task.detached(priority: .utility) {
      try Self.decode(data, maxPixelSize: 1024)
    }.value
    try Task.checkCancellation()
    return image
  }

  static func read(request: URLRequest, session: URLSession, maxBytes: Int) async throws -> Data {
    do {
      try Task.checkCancellation()
      guard maxBytes > 0 else { throw failure("Invalid image size limit.") }
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw failure("Image is unavailable.")
      }
      let types: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif",
        "image/avif", "image/tiff",
      ]
      guard types.contains(http.mimeType?.lowercased() ?? ""),
        response.expectedContentLength <= maxBytes
      else { throw failure("Unsupported or oversized image.") }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < maxBytes else { throw failure("Image is too large.") }
        data.append(byte)
      }
      return data
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let failure = error as? WorkspaceError { throw failure }
      throw failure("Image could not be loaded.")
    }
  }

  static func decode(_ data: Data, maxPixelSize: Int) throws -> CGImage {
    guard maxPixelSize > 0,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 100_000, height <= 100_000,
      Double(width) * Double(height) <= 100_000_000,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw failure("Image format is not supported.") }
    return image
  }

  static func failure(_ message: String) -> WorkspaceError {
    WorkspaceError(message: message, violations: [])
  }
}
