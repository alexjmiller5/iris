import Foundation

@MainActor
struct NativeLinkIdentityStore {
  let file: URL
  private let workspace: URL

  private struct FileStamp: Codable, Equatable {
    let volume: UUID
    let inode: UInt64
    let created: Date
  }

  private struct Preferences: Codable {
    let version: Int
    let id: UUID
    let stamp: FileStamp
  }

  init(root: URL, workspace: URL) {
    self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
    let scope = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: workspace)
      .directory.lastPathComponent
    file = root.appendingPathComponent("link-identities", isDirectory: true)
      .appendingPathComponent(scope + ".json")
  }

  func load() throws -> NativeWorkspaceBinding? {
    let stamp = try currentStamp()
    guard let saved = try read(), saved.stamp == stamp else { return nil }
    return .local(saved.id)
  }

  func create() throws -> NativeWorkspaceBinding {
    let stamp = try currentStamp()
    if let saved = try read(), saved.stamp == stamp { return .local(saved.id) }
    let saved = Preferences(version: 1, id: UUID(), stamp: stamp)
    do {
      let directory = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try JSONEncoder().encode(saved).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return .local(saved.id)
    } catch {
      throw WorkspaceError(message: "A local link could not be saved. Try again before copying it.", violations: [])
    }
  }

  private func read() throws -> Preferences? {
    do {
      let saved = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
      guard saved.version == 1, saved.stamp.inode > 0,
        saved.stamp.created.timeIntervalSinceReferenceDate.isFinite
      else { throw Self.readError }
      return saved
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch { throw Self.readError }
  }

  private func currentStamp() throws -> FileStamp {
    do {
      guard workspace.isFileURL, file.isFileURL else { throw Self.fileError }
      var fresh = workspace
      fresh.removeAllCachedResourceValues()
      let values = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey])
      let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let volumeText = values.volumeUUIDString, let volume = UUID(uuidString: volumeText),
        let inode = attributes[.systemFileNumber] as? NSNumber, inode.uint64Value > 0,
        let created = attributes[.creationDate] as? Date
      else { throw Self.fileError }
      return FileStamp(volume: volume, inode: inode.uint64Value, created: created)
    } catch { throw Self.fileError }
  }

  private static var readError: WorkspaceError {
    WorkspaceError(message: "Local link preferences could not be read. The saved file has been kept.", violations: [])
  }

  private static var fileError: WorkspaceError {
    WorkspaceError(message: "This database file cannot be identified for a local link.", violations: [])
  }
}
