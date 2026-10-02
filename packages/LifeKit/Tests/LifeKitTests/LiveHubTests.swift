import Foundation
import Testing

@testable import LifeKit

/// Opt-in against scripts/test-hub.ts only. No real account values belong here.
@MainActor
struct LiveHubTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_SERVICES_HUB"] != nil))
  func nativeHTTPUsageAndCompleteNotificationFeed() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["LIFE_UI_TEST_SERVICES_HUB"])
    let hub = try HubTransport(endpoint: endpoint, token: "fixture")
    let workspace = try NativeWorkspace(path: ":memory:")
    let usage = try await workspace.usage(using: hub)
    #expect(usage.metrics.count == 4)
    #expect(usage.metrics["d1_storage_bytes"]?.used == nil)
    let principal = try #require(usage.byPrincipal.first { $0.label == "Example device" })
    #expect(principal.rowsRead == 1234)
    #expect(principal.rowsWritten == 56)
    #expect(principal.requests == 78)
    let feed = try await workspace.notifications(using: hub)
    #expect(feed.notifications.count == 205)
    #expect(feed.notifications.last?.id == "fixture:205")
    #expect(try await workspace.notificationPresentation(feed, baseline: nil).notifications.isEmpty)
    try await workspace.close()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"] != nil))
  func nativeHTTPPullOfflineEditAndPush() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("replica.sqlite").path
    let hub = try HubTransport(endpoint: endpoint, token: "fixture")
    let first = try NativeWorkspace(path: path)
    let pulled = try await first.sync(using: hub)
    #expect(pulled.pulled > 0)
    #expect(try await first.catalog().tables.contains { $0["id"] == .string("widgets") })
    let title = "Native fixture \(UUID().uuidString)"
    let created = try await first.write(
      table: "widgets",
      patch: ["title": .string(title), "body": .string("# Offline source"), "quantity": .number(7)])
    try await first.close()
    let reopened = try NativeWorkspace(path: path)
    #expect(try await reopened.status().pendingUiEdits == 1)
    let restored = try #require(try await reopened.rows(table: "widgets", search: title).first)
    #expect(restored.record["body"] == .string("# Offline source"))
    _ = try await reopened.write(
      table: "widgets",
      patch: [
        "id": .string(restored.id),
        "body": .string("# Native source\n\nPersisted offline, then synced."),
      ], expectedUpdatedAt: restored.record["updated_at"]?.text)
    let receipt = try await reopened.sync(using: hub)
    #expect(receipt.rejected.isEmpty)
    #expect(try await reopened.status().pendingUiEdits == 0)
    #expect(receipt.pushed > 0)
    let response = try await hub.post(
      route: "/v1/rows/pull",
      body: [
        "table": .string("widgets"),
        "columns": .array(["id", "title", "body", "quantity"].map(JSONValue.string)),
        "since": .string(""), "limit": .number(200),
      ])
    guard case .object(let envelope) = response.data, case .array(let rows) = envelope["rows"]
    else {
      Issue.record("Invalid hub response")
      return
    }
    let row = rows.compactMap {
      if case .object(let row) = $0 { return row }
      return nil
    }.first { $0["id"] == created["id"] }
    #expect(row?["body"] == .string("# Native source\n\nPersisted offline, then synced."))
    #expect(row?["quantity"] == .number(7))
    try await reopened.close()
  }
}
