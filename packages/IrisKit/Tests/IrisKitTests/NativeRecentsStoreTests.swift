import Foundation
import Testing

@testable import IrisKit

struct NativeRecentsStoreTests {
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func store(_ root: URL, workspace: URL? = nil) -> NativeRecentsStore {
    NativeRecentsStore(root: root, workspace: workspace ?? root.appendingPathComponent("local.sqlite"))
  }

  private func pending(_ destinations: [NativeDestination]) -> [NativeRecentEntry] {
    destinations.map(NativeRecentEntry.init(pending:))
  }

  @Test func roundTripStoresIdentitiesWithTheirDisplaySnapshot() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    #expect(try preferences.load().isEmpty)
    let destination = NativeDestination(table: "notes", viewID: "view-1", rowID: "row-1")
    let shown = NativeRecentEntry(
      destination: destination, label: "Shown title", isTrashed: true, loading: false)
    let gone = NativeRecentEntry(
      destination: NativeDestination(table: "notes", rowID: "gone"), label: "Last title",
      loading: false, unavailable: "Outside this replica")
    let unresolved = NativeRecentEntry(pending: NativeDestination(table: "notes"))
    _ = try preferences.update { _ in [shown, gone, unresolved] }
    #expect(try store(root).load() == [shown, gone, unresolved])
    let data = try Data(contentsOf: preferences.file)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["version", "entries"])
    #expect(json["version"] as? Int == 2)
    let entries = try #require(json["entries"] as? [[String: Any]])
    #expect(Set(entries[0].keys) == ["table", "view", "row", "label", "trashed", "unavailable"])
    #expect(entries[0]["label"] as? String == "Shown title" && entries[0]["trashed"] as? Bool == true)
    #expect(entries[0]["unavailable"] is NSNull)
    #expect(entries[1]["unavailable"] as? String == "Outside this replica")
    // An entry never resolved on this device stores its identity only.
    #expect(entries[2] as? [String: String] == ["table": "notes"])
    #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
    let directoryMode = try FileManager.default.attributesOfItem(
      atPath: preferences.file.deletingLastPathComponent().path)[.posixPermissions] as? Int
    let fileMode = try FileManager.default.attributesOfItem(
      atPath: preferences.file.path)[.posixPermissions] as? Int
    #expect(directoryMode == 0o700 && fileMode == 0o600)
  }

  @Test func versionOneTupleHistoryReopensPendingWithoutLosingEntries() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    try FileManager.default.createDirectory(
      at: preferences.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":1,"entries":[{"table":"notes","row":"a"},{"table":"notes","view":"v"}]}"#.utf8)
      .write(to: preferences.file)
    #expect(try preferences.load() == pending([
      NativeDestination(table: "notes", rowID: "a"), NativeDestination(table: "notes", viewID: "v"),
    ]))
    #expect(try preferences.load().allSatisfy(\.loading))
  }

  @Test func newestEightRemainAndReopeningMovesOnlyThatIdentityToFront() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    _ = try preferences.load()
    for index in 0..<10 {
      _ = try preferences.update { pending([NativeDestination(table: "notes", rowID: "row\(index)")]) + $0 }
    }
    #expect(try preferences.load().map(\.destination.rowID) == ["row9", "row8", "row7", "row6", "row5", "row4", "row3", "row2"])
    _ = try preferences.update { pending([NativeDestination(table: "notes", rowID: "row5")]) + $0 }
    #expect(try preferences.load().map(\.destination.rowID) == ["row5", "row9", "row8", "row7", "row6", "row4", "row3", "row2"])
  }

  @Test func unicodeIDsRemainByteDistinctThroughPersistenceAndRemoval() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    _ = try preferences.load()
    let composed = NativeDestination(table: "notes", rowID: "caf\u{00e9}")
    let decomposed = NativeDestination(table: "notes", rowID: "cafe\u{0301}")
    let spaced = NativeDestination(table: "notes", rowID: " cafe\u{0301} ")
    let otherTable = NativeDestination(table: "other", rowID: "caf\u{00e9}")
    let otherView = NativeDestination(table: "notes", viewID: "view", rowID: "caf\u{00e9}")
    _ = try preferences.update { _ in pending([composed, decomposed, spaced, otherTable, otherView]) }
    let reopened = store(root)
    #expect(try reopened.load().count == 5)
    let remaining = try reopened.update { $0.filter { $0.destination != composed } }
    #expect(remaining.count == 4)
    #expect(remaining.first?.destination.rowID.map { Array($0.utf8) } == [99, 97, 102, 101, 204, 129])
    #expect(remaining[1].destination.rowID.map { Array($0.utf8) } == [32, 99, 97, 102, 101, 204, 129, 32])
  }

  @Test func appOwnedIdentitySurvivesContainerRelocationWithoutSharingOtherWorkspaces() throws {
    let parent = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let firstRoot = parent.appendingPathComponent("container-one")
    let movedRoot = parent.appendingPathComponent("container-two")
    let first = store(firstRoot)
    _ = try first.load()
    let destination = NativeDestination(table: "notes")
    _ = try first.update { _ in pending([destination]) }
    try FileManager.default.copyItem(at: firstRoot, to: movedRoot)
    #expect(try store(movedRoot).load() == pending([destination]))
    let replica = store(movedRoot, workspace: movedRoot.appendingPathComponent("replicas/fixture.sqlite"))
    #expect(try replica.load().isEmpty)
    let external = parent.appendingPathComponent("external/workspace.sqlite")
    let externalStore = store(firstRoot, workspace: external)
    _ = try externalStore.load()
    _ = try externalStore.update { _ in pending([NativeDestination(table: "external")]) }
    #expect(try store(firstRoot, workspace: parent.appendingPathComponent("other/workspace.sqlite")).load().isEmpty)
    let identity = EditorDraftStore(root: firstRoot.appendingPathComponent("drafts"), workspace: external)
      .directory.lastPathComponent
    #expect(externalStore.file.deletingPathExtension().lastPathComponent == identity)
  }

  @Test(arguments: ["broken json", "{\"version\":3,\"entries\":[]}", "{\"version\":1,\"entries\":\"wrong\"}"])
  func unreadPreferencesCannotBeOverwrittenByLaterChanges(contents: String) throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    try FileManager.default.createDirectory(at: preferences.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data(contents.utf8)
    try bytes.write(to: preferences.file)
    #expect(throws: WorkspaceError.self) { try preferences.load() }
    #expect(throws: WorkspaceError.self) {
      try preferences.update { _ in pending([NativeDestination(table: "notes")]) }
    }
    #expect(try Data(contentsOf: preferences.file) == bytes)
  }

  @Test func unloadedStoreCannotReplaceAnExistingHistory() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    #expect(throws: WorkspaceError.self) { try preferences.update { _ in [] } }
    #expect(!FileManager.default.fileExists(atPath: preferences.file.path))
  }

  @Test @MainActor func inaccessibleDirectoryIsNotMistakenForMissingHistory() async throws {
    let root = temporaryRoot()
    let preferences = store(root)
    let directory = preferences.file.deletingLastPathComponent()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try preferences.load()
    _ = try preferences.update { _ in pending([NativeDestination(table: "preserve")]) }
    let before = try Data(contentsOf: preferences.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    let reopened = store(root)
    #expect(throws: WorkspaceError.self) { try reopened.load() }
    let model = NativeRecentsModel(store: reopened, resolve: { _ in
      throw WorkspaceError(message: "Synthetic unavailable destination", violations: [])
    })
    await model.navigationSucceeded(NativeDestination(table: "new"))
    #expect(model.storageError != nil)
    #expect(model.destinations == [NativeDestination(table: "new")])
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    #expect(mode == 0o000)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try Data(contentsOf: preferences.file) == before)
  }

  @Test func separateWindowsMergeTheLatestFileBeforeRememberingAndRemoving() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = store(root)
    let second = store(root)
    _ = try first.load()
    _ = try second.load()
    let a = NativeDestination(table: "a")
    let b = NativeDestination(table: "b")
    _ = try first.update { pending([a]) + $0 }
    #expect(try second.update { pending([b]) + $0 } == pending([b, a]))
    #expect(try first.update { $0.filter { $0.destination != a } } == pending([b]))
    #expect(try store(root).load() == pending([b]))
  }

  @Test func aFileBecomingUnreadableAfterLoadIsKeptAndDisablesFurtherWrites() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    _ = try preferences.load()
    _ = try preferences.update { _ in pending([NativeDestination(table: "old")]) }
    let damaged = Data("damaged by another writer".utf8)
    try damaged.write(to: preferences.file)
    #expect(throws: WorkspaceError.self) { try preferences.update { pending([NativeDestination(table: "new")]) + $0 } }
    #expect(try Data(contentsOf: preferences.file) == damaged)
    // Even a later externally repaired file requires an explicit new read/session.
    let repaired = Data("{\"version\":1,\"entries\":[]}".utf8)
    try repaired.write(to: preferences.file)
    #expect(throws: WorkspaceError.self) { try preferences.update { _ in [] } }
    #expect(try Data(contentsOf: preferences.file) == repaired)
  }

  @Test func invalidEmptyIdentitiesAreOmittedWithoutTrimmingValidIdentifiers() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = store(root)
    _ = try preferences.load()
    let valid = NativeDestination(table: " notes ", viewID: " view ", rowID: " row ")
    #expect(try preferences.update { _ in pending([
      NativeDestination(table: ""), NativeDestination(table: "notes", viewID: ""),
      NativeDestination(table: "notes", rowID: ""), valid,
    ]) } == pending([valid]))
  }
}
