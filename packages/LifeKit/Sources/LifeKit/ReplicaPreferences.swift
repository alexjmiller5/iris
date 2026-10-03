import CryptoKit
import Foundation

struct ReplicaPreferences: Codable, Equatable {
  var maxRows: Int? = nil
  var tables: [String: Bool] = [:]

  static func parse(limit: String, tables: [String: Bool]) throws -> Self {
    let text = limit.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return Self(tables: tables) }
    guard let count = Int(text) else { throw invalidLimit }
    let result = Self(maxRows: count, tables: tables)
    try result.validate()
    return result
  }

  func validate() throws {
    guard let maxRows else { return }
    guard maxRows >= 0 else { throw Self.invalidLimit }
    do { try CoreContract.checkInteger(maxRows) } catch { throw Self.invalidLimit }
  }

  private static var invalidLimit: WorkspaceError {
    WorkspaceError(
      message: "Enter a nonnegative whole number, or leave the limit blank.", violations: [])
  }
}

struct ReplicaPreferenceStore {
  let file: URL

  /// The caller supplies HubTransport's canonical endpoint, without any credential.
  init(root: URL, endpoint: String) {
    let key = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    file = root.appendingPathComponent(key + ".json")
  }

  func load() throws -> ReplicaPreferences {
    guard FileManager.default.fileExists(atPath: file.path) else { return ReplicaPreferences() }
    do {
      let preferences = try JSONDecoder().decode(
        ReplicaPreferences.self, from: Data(contentsOf: file))
      try preferences.validate()
      return preferences
    } catch {
      throw WorkspaceError(
        message: "Download settings could not be read. The saved file has been kept.",
        violations: [])
    }
  }

  func save(_ preferences: ReplicaPreferences) throws {
    try preferences.validate()
    do {
      let directory = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      throw WorkspaceError(message: "Download settings could not be saved.", violations: [])
    }
  }
}
