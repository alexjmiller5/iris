import Foundation
import Testing

@testable import IrisKit

struct CoreContractTests {
  private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }

  @Test func nullableFieldsAndUnknownNotificationDataRoundTrip() throws {
    let event = CoreHubNotification(
      seq: 1, id: "event:1", createdAt: "2026-01-01T00:00:00.000Z",
      producer: "future", type: "new-type", severity: "info", title: "Fixture", body: "Body",
      data: .object(["enabled": .bool(true), "empty": .null, "items": .array([.number(2)])]),
      readAt: nil)
    let feed = CoreNotificationFeed(
      notifications: [event], nextCursor: nil, latestCursor: 1, unreadCount: 1)
    let encoded = try json(feed)
    #expect(encoded["next_cursor"] is NSNull)
    let events = try #require(encoded["notifications"] as? [[String: Any]])
    #expect(events[0]["read_at"] is NSNull)
    #expect(
      try JSONDecoder().decode(CoreNotificationFeed.self, from: JSONEncoder().encode(feed)) == feed)
    var malformed = events[0]
    malformed.removeValue(forKey: "read_at")
    #expect(throws: Error.self) {
      try JSONDecoder().decode(
        CoreHubNotification.self, from: JSONSerialization.data(withJSONObject: malformed))
    }
    let metric = CoreUsageMetric(
      kind: .gauge, unit: "bytes", used: nil, allowance: nil, cap: nil, alertAt: [], measuredAt: nil
    )
    for key in ["used", "allowance", "cap", "measured_at"] {
      #expect(try json(metric)[key] is NSNull)
    }
  }

  @Test func optionalNullablePropertiesKeepAllThreeStates() throws {
    let decoder = JSONDecoder()
    let missing = try decoder.decode(CoreProperty.self, from: Data(#"{"col":"title"}"#.utf8))
    let null = try decoder.decode(
      CoreProperty.self, from: Data(#"{"col":"title","label":null}"#.utf8))
    let value = try decoder.decode(
      CoreProperty.self, from: Data(#"{"col":"title","label":"Title"}"#.utf8))
    #expect(missing.label == .missing)
    #expect(null.label == .null)
    #expect(value.label == .value("Title"))
    #expect(try json(missing)["label"] == nil)
    #expect(try json(null)["label"] is NSNull)
    #expect(try json(value)["label"] as? String == "Title")
    #expect(try json(CoreFilter(column: "title", op: .empty))["value"] == nil)
    #expect(try json(CoreFilter(column: "title", op: .eq, value: .null))["value"] is NSNull)
    #expect(
      try decoder.decode(
        CoreFilter.self, from: Data(#"{"column":"title","op":"eq","value":null}"#.utf8)
      ).value == .some(.null))
  }

  @Test func unsafeIntegerAndUnknownRequiredEnumFail() throws {
    #expect(throws: Error.self) {
      try JSONEncoder().encode(CoreView(table: "items", offset: 9_007_199_254_740_992))
    }
    #expect(throws: Error.self) {
      try JSONDecoder().decode(
        CoreView.self, from: Data(#"{"table":"items","offset":9007199254740992}"#.utf8))
    }
    #expect(throws: Error.self) {
      try JSONDecoder().decode(
        CoreFilter.self, from: Data(#"{"column":"title","op":"future"}"#.utf8))
    }
  }

  @Test @MainActor func generatedViewRunsThroughTheActualNativeBridge() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let rows = try await workspace.rows(
      view: CoreView(
        table: "notes",
        filters: [CoreFilter(column: "title", op: .contains, value: .string("place"))],
        sort: [CoreSort(column: "title", direction: .desc)], limit: 1))
    #expect(rows.count == 1)
    #expect(rows[0].label == "A place to start")
    let referenced = try await workspace.rows(
      view: CoreView(
        table: "notes", filters: [CoreFilter(column: "id", op: .eq, value: .string(rows[0].id))]))
    #expect(referenced == rows)
    try await workspace.close()
  }

  @Test @MainActor func mismatchedBundleIsRejectedBeforeDatabaseOpen() throws {
    let runtime = try IrisCoreRuntime(
      script:
        "globalThis.IrisCore = {validateRow: () => []}; globalThis.IrisNative = {contractHash: 'wrong'};"
    )
    #expect(throws: Error.self) { try NativeWorkspace(path: ":memory:", runtime: runtime) }
  }
}
