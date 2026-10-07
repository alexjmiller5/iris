import Foundation
import GRDB

/// An explicit file choice is user state, separate from hub credentials and replicas.
struct LocalDatabaseSelection {
  let root: URL
  private var file: URL { root.appendingPathComponent("selected-database.bookmark") }

  func load() throws -> URL? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    var stale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
      let options: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    let url = try URL(
      resolvingBookmarkData: Data(contentsOf: file), options: options,
      relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    // Do not replace a missing file with a new empty database or another replica.
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
      throw WorkspaceError(
        message: "The selected database is unavailable. Reopen its file to continue.",
        violations: [])
    }
    if stale { try save(url) }
    return url
  }

  func save(_ url: URL) throws {
    #if os(macOS)
      let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
      let options: URL.BookmarkCreationOptions = []
    #endif
    let data = try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// Clear the file choice before installing a credential, restoring the exact
  /// bookmark if secure storage refuses the candidate. No fallible file work
  /// follows a successful credential installation.
  func clear(install: () throws -> Void) throws {
    let previous =
      FileManager.default.fileExists(atPath: file.path)
      ? try Data(contentsOf: file) : nil
    try clear()
    do {
      try install()
    } catch {
      if let previous {
        try previous.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      throw error
    }
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
}

/// A separate, long-lived read connection observes all committed writers, including
/// other processes and this app. It never shares an in-flight core transaction.
final class LocalDatabaseObserver {
  private let database: DatabaseQueue
  private(set) var version: Int

  init(path: String) throws {
    var configuration = Configuration()
    // SQLite may need to create WAL shared-memory sidecars after another writer
    // changes journal mode. This connection executes only read operations.
    configuration.busyMode = .immediateError
    database = try DatabaseQueue(
      path: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path,
      configuration: configuration)
    version = try database.read { try Int.fetchOne($0, sql: "PRAGMA data_version")! }
  }

  func currentVersion() throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "PRAGMA data_version")! }
  }

  func acknowledge(_ value: Int) { version = value }
}
