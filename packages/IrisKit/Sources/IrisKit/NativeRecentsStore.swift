import Foundation

final class NativeRecentsStore {
  let file: URL
  private var readable = false

  private struct Preferences: Codable {
    let version: Int
    let entries: [NativeDestination]
  }

  init(root: URL, workspace: URL) {
    let scope = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: workspace)
      .directory.lastPathComponent
    file = root.appendingPathComponent("recents", isDirectory: true)
      .appendingPathComponent(scope + ".json")
  }

  func load() throws -> [NativeDestination] {
    readable = false
    let entries = try read()
    readable = true
    return entries
  }

  func update(_ change: ([NativeDestination]) -> [NativeDestination]) throws -> [NativeDestination] {
    guard readable else { throw Self.readError }
    let stored: [NativeDestination]
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
      try JSONEncoder().encode(Preferences(version: 1, entries: entries))
        .write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return entries
    } catch {
      throw WorkspaceError(message: "Recents could not be saved on this device.", violations: [])
    }
  }

  static func bounded(_ entries: [NativeDestination]) -> [NativeDestination] {
    var seen = Set<NativeDestination>()
    var result: [NativeDestination] = []
    for entry in entries {
      guard !entry.table.isEmpty, entry.viewID?.isEmpty != true, entry.rowID?.isEmpty != true,
        seen.insert(entry).inserted
      else { continue }
      result.append(entry)
      if result.count == 8 { break }
    }
    return result
  }

  private func read() throws -> [NativeDestination] {
    do {
      let preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
      guard preferences.version == 1 else { throw Self.readError }
      return Self.bounded(preferences.entries)
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
