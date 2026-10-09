import Foundation

/// The app's private files: the local database, replicas, drafts, recents, bookmarks
/// and alerts. An install made before the app was named Iris kept them under
/// "life-ui"; the first launch moves that directory once and leaves a marker so the
/// hub connection screen can explain why the device must sign in again.
enum ApplicationSupport {
  private static let legacyName = "life-ui"
  private static let marker = ".renamed-from-life-ui"

  static func root() throws -> URL {
    try adopt(
      base: FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
        create: true))
  }

  static func adopt(base: URL) throws -> URL {
    let fileManager = FileManager.default
    let root = base.appendingPathComponent("iris", isDirectory: true)
    let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
    if !fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: legacy.path) {
      try fileManager.moveItem(at: legacy, to: root)
      fileManager.createFile(atPath: root.appendingPathComponent(marker).path, contents: nil)
    }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func renamed(root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path)
  }

  static func acknowledgeRename(root: URL) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(marker))
  }
}
