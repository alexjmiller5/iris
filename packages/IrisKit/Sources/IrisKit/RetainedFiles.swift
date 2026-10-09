import Foundation
import ImageIO
import UniformTypeIdentifiers

func retainedFileRoute(key: String) throws -> String {
  let parts = key.split(separator: "/", omittingEmptySubsequences: false)
  guard !key.isEmpty, key.count <= 2048, !key.contains("://"), !key.contains("\\"),
    !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
    parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  else { throw WorkspaceError(message: "Invalid retained file key.", violations: []) }
  let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
  let encoded = try parts.map { part in
    guard let encoded = String(part).addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw WorkspaceError(message: "Invalid retained file key.", violations: [])
    }
    return encoded
  }
  return "/v1/files/" + encoded.joined(separator: "/")
}

/// The owner retains this object for as long as a preview needs the local file.
final class RetainedFile: Sendable {
  let url: URL
  let contentType: String
  private let directory: URL
  init(data: Data, contentType: String, name: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "iris-file-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let safeName =
      name.split(separator: "/").last.map(String.init).flatMap {
        $0 == "." || $0 == ".." ? nil : $0
      } ?? "attachment"
    url = directory.appendingPathComponent(safeName)
    self.contentType = contentType
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
  /// Only a bounded, static raster crosses into the editor island. Original
  /// attachment bytes remain private to the native file-preview owner.
  func imagePreview() async throws -> Data {
    try Task.checkCancellation()
    guard
      ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/bmp"].contains(
        contentType)
    else { throw ImagePreviewLoader.failure("This file cannot be displayed as an image.") }
    let url = url
    let data = try await Task.detached(priority: .utility) {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard size <= 8 * 1024 * 1024 else {
        throw ImagePreviewLoader.failure("Image is too large.")
      }
      let bytes = try Data(contentsOf: url)
      let image = try ImagePreviewLoader.decode(bytes, maxPixelSize: 1024)
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output, UTType.png.identifier as CFString, 1, nil)
      else { throw ImagePreviewLoader.failure("Image format is not supported.") }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw ImagePreviewLoader.failure("Image format is not supported.")
      }
      return output as Data
    }.value
    try Task.checkCancellation()
    return data
  }

  func dispose() { try? FileManager.default.removeItem(at: directory) }
  deinit { dispose() }
}
