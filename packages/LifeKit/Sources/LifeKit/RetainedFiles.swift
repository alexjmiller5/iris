import Foundation

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
      "life-file-" + UUID().uuidString, isDirectory: true)
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
  func dispose() { try? FileManager.default.removeItem(at: directory) }
  deinit { dispose() }
}
