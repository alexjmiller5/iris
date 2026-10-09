import Foundation
import Testing

@testable import IrisKit

struct ReplicaPreferencesTests {
  @Test func savedChoicesSurviveRecreationAndStayIsolatedByEndpoint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ReplicaPreferenceStore(root: root, endpoint: "https://first.invalid/hub")
    let second = ReplicaPreferenceStore(root: root, endpoint: "https://second.invalid/hub")
    let preferences = ReplicaPreferences(
      maxRows: 250, tables: ["notes": true, "history": false, "not_in_current_catalog": false])
    try first.save(preferences)
    let recreated = ReplicaPreferenceStore(root: root, endpoint: "https://first.invalid/hub")
    #expect(try recreated.load() == preferences)
    #expect(try second.load() == ReplicaPreferences())
    #expect(first.file != second.file)
    let data = try Data(contentsOf: first.file)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["maxRows", "tables"])
    #expect(!String(decoding: data, as: UTF8.self).contains("first.invalid"))
    #expect(!first.file.lastPathComponent.contains("first.invalid"))
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: first.file.path)[.posixPermissions] as? Int
    #expect(directoryMode == 0o700 && fileMode == 0o600)
  }

  @Test func blankLimitDelegatesToCoreAndZeroRemainsAnExplicitLimit() throws {
    let tables = ["notes": true, "history": false]
    let automatic = try ReplicaPreferences.parse(limit: "  ", tables: tables)
    let zero = try ReplicaPreferences.parse(limit: "0", tables: tables)
    #expect(automatic.maxRows == nil && automatic.tables == tables)
    #expect(zero.maxRows == 0 && zero.tables == tables)
    #expect(try ReplicaPreferences.parse(limit: " 250 ", tables: tables).maxRows == 250)
    for invalid in ["-1", "1.5", "abc", "9007199254740992"] {
      #expect(throws: WorkspaceError.self) {
        try ReplicaPreferences.parse(limit: invalid, tables: tables)
      }
    }
  }

  @Test func corruptPreferencesAreKeptAndInvalidSaveCannotReplacePreviousChoices() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReplicaPreferenceStore(root: root, endpoint: "https://fixture.invalid")
    let valid = ReplicaPreferences(maxRows: 10, tables: ["notes": false])
    try store.save(valid)
    let saved = try Data(contentsOf: store.file)
    #expect(throws: WorkspaceError.self) {
      try store.save(ReplicaPreferences(maxRows: -1))
    }
    #expect(try Data(contentsOf: store.file) == saved)
    let damaged = Data("not valid JSON".utf8)
    try damaged.write(to: store.file)
    #expect(throws: WorkspaceError.self) { try store.load() }
    #expect(try Data(contentsOf: store.file) == damaged)
  }
}
