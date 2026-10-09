import Foundation
import IrisExtensionSupport
import Testing

@testable import IrisKit

@MainActor struct WidgetSnapshotTests {
  @Test func queuedSnapshotContainsCommittedRowsAndRemainsIndependentOfLaterEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: root.appendingPathComponent("live.sqlite").path)
    try await workspace.createSample()
    let plan = try await workspace.prepareReadPlan(
      CorePrepareReadPlanArgs(
        workspaceID: "workspace", replicaID: "replica", table: "notes", kind: .list))
    let source = try #require(
      try await workspace.rows(view: CoreView(table: "notes", limit: 1)).first)
    let first = try await workspace.write(
      table: "notes",
      patch: ["id": source.record["id"]!, "title": .string("First committed title")],
      expectedUpdatedAt: source.record["updated_at"]?.text)
    let snapshot = root.appendingPathComponent("snapshot.sqlite")
    try await workspace.exportWidgetSnapshot(to: snapshot)
    _ = try await workspace.write(
      table: "notes", patch: ["id": first["id"]!, "title": .string("Later live title")],
      expectedUpdatedAt: first["updated_at"]?.text)
    try await workspace.close()
    let result = try WidgetPlanReader(databaseURL: snapshot).read(
      plan: plan, workspaceID: "workspace", replicaID: "replica")
    #expect(result.rows.contains { $0["title"] == .string("First committed title") })
    #expect(!result.rows.contains { $0["title"] == .string("Later live title") })
  }

  @Test func exportNeverOverwritesAnExistingDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("existing")
    try Data("sentinel".utf8).write(to: target)
    let workspace = try NativeWorkspace(path: ":memory:")
    await #expect(throws: (any Error).self) { try await workspace.exportWidgetSnapshot(to: target) }
    #expect(try Data(contentsOf: target) == Data("sentinel".utf8))
    try await workspace.close()
  }
}
