import CryptoKit
import Foundation

struct PendingEditorWrite: Codable {
  let id: String
  let patch: WorkspaceRecord
  let expectedUpdatedAt: String?
}

struct StoredEditorDraft: Codable, Identifiable {
  let id: String
  let table: String
  let recordID: String?
  let draft: RecordDraft
  let failure: String?
  let failedPatch: WorkspaceRecord?
  let pendingWrite: PendingEditorWrite?
  let autosavePaused: Bool?
  let undoUnconfirmed: Bool?
  let modifiedAt: Date

  init(
    id: String = UUID().uuidString, table: String, recordID: String?, draft: RecordDraft,
    failure: String?, failedPatch: WorkspaceRecord?, pendingWrite: PendingEditorWrite? = nil,
    autosavePaused: Bool? = nil, undoUnconfirmed: Bool? = nil,
    modifiedAt: Date = Date()
  ) {
    self.id = id
    self.table = table
    self.recordID = recordID
    self.draft = draft
    self.failure = failure
    self.failedPatch = failedPatch
    self.pendingWrite = pendingWrite
    self.autosavePaused = autosavePaused
    self.undoUnconfirmed = undoUnconfirmed
    self.modifiedAt = modifiedAt
  }
}

struct EditorDraftStore {
  let directory: URL

  init(root: URL, workspace: URL) {
    let canonical = workspace.standardizedFileURL.resolvingSymlinksInPath()
    let appState =
      root.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
      .path + "/"
    // iOS can relocate the whole app container during an update. Files inside
    // this app's state keep their relative identity; external databases keep
    // their absolute canonical identity. Separate state roots remain isolated.
    let identity =
      canonical.path.hasPrefix(appState)
      ? "app-state:" + String(canonical.path.dropFirst(appState.count))
      : canonical.absoluteString
    directory = root.appendingPathComponent(Self.hash(identity), isDirectory: true)
  }

  static func key(table: String, recordID: String?, draftID: String = "") -> String {
    hash(String(data: try! JSONEncoder().encode([table, recordID, draftID]), encoding: .utf8)!)
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func url(table: String, recordID: String?, draftID: String) -> URL {
    directory.appendingPathComponent(
      Self.key(table: table, recordID: recordID, draftID: draftID) + ".json")
  }

  func load(table: String, recordID: String?) throws -> StoredEditorDraft? {
    let matches = try all().filter { $0.table == table && $0.recordID == recordID }
    guard matches.count < 2 else {
      throw WorkspaceError(message: "Choose which unsaved draft to resume.", violations: [])
    }
    return matches.first
  }

  func all() throws -> [StoredEditorDraft] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.map {
      try JSONDecoder().decode(StoredEditorDraft.self, from: Data(contentsOf: $0))
    }.sorted { $0.modifiedAt < $1.modifiedAt }
  }

  func save(_ saved: StoredEditorDraft) throws {
    // The directory protects both the final file and Foundation's atomic-write
    // temporary file. Workspace identity survives relaunch; each editor owns a
    // separate variant, including multiple new-record drafts in the same table.
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let file = url(table: saved.table, recordID: saved.recordID, draftID: saved.id)
    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  func remove(table: String, recordID: String?, draftID: String) throws {
    let file = url(table: table, recordID: recordID, draftID: draftID)
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
}
