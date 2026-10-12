import Foundation

final class NativeRecentsStore {
  let file: URL
  private var readable = false

  /// Version 2 entries carry a display snapshot; version 1 held identity tuples only.
  private struct Preferences: Codable {
    let version: Int
    let entries: [NativeRecentEntry]
  }

  init(root: URL, workspace: URL) {
    let scope = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: workspace)
      .directory.lastPathComponent
    file = root.appendingPathComponent("recents", isDirectory: true)
      .appendingPathComponent(scope + ".json")
  }

  func load() throws -> [NativeRecentEntry] {
    readable = false
    let entries = try read()
    readable = true
    return entries
  }

  func update(_ change: ([NativeRecentEntry]) -> [NativeRecentEntry]) throws -> [NativeRecentEntry] {
    guard readable else { throw Self.readError }
    let stored: [NativeRecentEntry]
    do {
      stored = try read()
    } catch {
      readable = false
      throw error
    }
    let entries = Self.bounded(change(stored))
    do {
      let directory = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try JSONEncoder().encode(Preferences(version: 2, entries: entries))
        .write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return entries
    } catch {
      throw WorkspaceError(message: "Recents could not be saved on this device.", violations: [])
    }
  }

  static func bounded(_ entries: [NativeRecentEntry]) -> [NativeRecentEntry] {
    var seen = Set<NativeDestination>()
    var result: [NativeRecentEntry] = []
    for entry in entries {
      let destination = entry.destination
      guard !destination.table.isEmpty, destination.viewID?.isEmpty != true,
        destination.rowID?.isEmpty != true, seen.insert(destination).inserted
      else { continue }
      result.append(entry)
      if result.count == 8 { break }
    }
    return result
  }

  private func read() throws -> [NativeRecentEntry] {
    do {
      let preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
      switch preferences.version {
      case 1: return Self.bounded(preferences.entries.map { NativeRecentEntry(pending: $0.destination) })
      case 2: return Self.bounded(preferences.entries)
      default: throw Self.readError
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      throw Self.readError
    }
  }

  private static var readError: WorkspaceError {
    WorkspaceError(message: "Recents could not be read. The saved file has been kept.", violations: [])
  }
}
