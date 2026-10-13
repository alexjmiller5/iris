import Foundation
import Testing

@testable import IrisKit

struct SkippedTableTests {
  private func detail(rows: Int? = 62_000, bytes: Int? = 4_200_000, waiting: Int = 0)
    -> CoreSkippedTableDetail
  {
    CoreSkippedTableDetail(table: "notes", rows: rows, estimatedBytes: bytes, waitingEdits: waiting)
  }

  @Test func suggestsIncludingAndARaisedLimitOnlyWhenTheLimitLeftTheTableOut() {
    let automatic = ReplicaPreferences(tables: ["topics": false])
    #expect(automatic.downloadChoices(for: detail()) == [.include, .limit(62_000)])
    #expect(
      ReplicaPreferences(maxRows: 100, tables: [:]).downloadChoices(for: detail())
        == [.include, .limit(62_000)])
    #expect(
      ReplicaPreferences(tables: ["notes": false]).downloadChoices(for: detail()) == [.include])
    #expect(automatic.downloadChoices(for: detail(rows: nil)) == [.include])
  }

  @Test func applyingAChoiceChangesOnlyThatSetting() {
    let preferences = ReplicaPreferences(maxRows: 10, tables: ["topics": false, "notes": false])
    #expect(
      preferences.applying(.include, to: "notes")
        == ReplicaPreferences(maxRows: 10, tables: ["topics": false, "notes": true]))
    #expect(
      preferences.applying(.limit(62_000), to: "notes")
        == ReplicaPreferences(maxRows: 62_000, tables: ["topics": false]))
  }

  @Test func knowsWhenTheNextRoundDownloadsIt() {
    #expect(!ReplicaPreferences().willDownload(detail()))
    #expect(ReplicaPreferences(tables: ["notes": true]).willDownload(detail()))
    #expect(ReplicaPreferences(maxRows: 62_000).willDownload(detail()))
    #expect(!ReplicaPreferences(maxRows: 1_000_000).willDownload(detail(rows: nil)))
  }

  @Test func describesSizeAndWaitingEdits() {
    #expect(SkippedTableText.size(detail()) == "62,000 rows · about 4.2 MB")
    #expect(SkippedTableText.size(detail(rows: 1, bytes: nil)) == "1 row")
    #expect(
      SkippedTableText.size(detail(rows: nil, bytes: nil))
        == "Row count unknown until the next sync")
    #expect(SkippedTableText.waiting(detail(waiting: 1)) == "1 earlier edit uploads once it syncs.")
    #expect(SkippedTableText.waiting(detail(waiting: 3)) == "3 earlier edits upload once it syncs.")
    #expect(SkippedTableText.waiting(detail()) == nil)
  }

  @Test func hiddenPromptsPersistPerEndpointAndSurviveDamage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DownloadPromptStore(root: root, endpoint: "https://first.invalid")
    #expect(store.load() == [])
    try store.save(["notes", "topics"])
    #expect(
      DownloadPromptStore(root: root, endpoint: "https://first.invalid").load() == [
        "notes", "topics",
      ])
    #expect(DownloadPromptStore(root: root, endpoint: "https://second.invalid").load() == [])
    #expect(
      store.file != ReplicaPreferenceStore(root: root, endpoint: "https://first.invalid").file)
    try Data("not JSON".utf8).write(to: store.file)
    #expect(store.load() == [], "A damaged file only shows the prompts again")
  }
}
