import Foundation
import Testing

@testable import LifeKit

@MainActor
struct NativeWorkspaceTests {
  @Test func catalogAndRecordLifecycleUsesSharedCore() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let catalog = try await workspace.catalog()
    #expect(catalog.tables.contains { $0["id"] == .string("notes") })
    #expect(
      catalog.properties.contains {
        $0["col"] == .string("body") && $0["type"] == .string("markdown")
      })
    let created = try await workspace.write(
      table: "notes",
      patch: [
        "title": .string("A synthetic note"),
        "body": .string("# Source\n\n**Markdown** and 'quotes'."),
      ])
    let id = try #require(created["id"])
    #expect(created["status"] == .string("Draft"))
    let edited = try await workspace.write(
      table: "notes", patch: ["id": id, "title": .string("Updated note")])
    #expect(edited["body"] == created["body"])
    let found = try await workspace.rows(table: "notes", search: "Updated")
    #expect(found.count == 1)
    #expect(found.first?.label == "Updated note")
    _ = try await workspace.write(table: "notes", patch: ["id": id, "deleted_at": .bool(true)])
    #expect(try await workspace.rows(table: "notes", search: "Updated").isEmpty)
    #expect(try await workspace.rows(table: "notes", search: "Updated", trash: true).count == 1)
    _ = try await workspace.write(table: "notes", patch: ["id": id, "deleted_at": .null])
    #expect(try await workspace.rows(table: "notes", search: "Updated").count == 1)
    try await workspace.close()
  }

  @Test func invalidWriteRollsBackAndQueueRecovers() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let created = try await workspace.write(table: "notes", patch: ["title": .string("Keep this")])
    let id = try #require(created["id"])
    do {
      _ = try await workspace.write(
        table: "notes", patch: ["id": id, "title": .string(""), "body": .string("Must roll back")])
      Issue.record("Invalid write succeeded")
    } catch let error as WorkspaceError {
      #expect(error.violations.contains { $0.col == "title" && $0.rule == "required" })
    }
    let row = try #require(try await workspace.rows(table: "notes", search: "Keep this").first)
    #expect(row.record == created)
    #expect(try await workspace.rows(table: "history").isEmpty)
    _ = try await workspace.write(
      table: "notes", patch: ["id": id, "body": .string("Valid update")])
    #expect(try await workspace.rows(table: "history").count == 1)
    try await workspace.close()
  }

  @Test func staleEditorCannotOverwriteNewerRevision() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let original = try await workspace.write(table: "notes", patch: ["title": .string("Original")])
    let id = try #require(original["id"])
    let revision = try #require(original["updated_at"]?.text)
    _ = try await workspace.write(
      table: "notes", patch: ["id": id, "title": .string("New revision")],
      expectedUpdatedAt: revision)
    do {
      _ = try await workspace.write(
        table: "notes", patch: ["id": id, "title": .string("Stale")], expectedUpdatedAt: revision)
      Issue.record("Stale edit succeeded")
    } catch let error as WorkspaceError {
      #expect(error.violations.contains { $0.rule == "conflict" })
    }
    #expect(try await workspace.rows(table: "notes", search: "New revision").count == 1)
    try await workspace.close()
  }

  @Test func concurrentCallsCannotEnterAnAwaitingTransaction() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          _ = try await workspace.write(
            table: "notes", patch: ["title": .string("Concurrent \(index)")])
          let rows = try await workspace.rows(table: "notes", search: "Concurrent")
          #expect(!rows.isEmpty)
        }
      }
      try await group.waitForAll()
    }
    #expect(try await workspace.rows(table: "notes", search: "Concurrent").count == 16)
    try await workspace.close()
  }

  @Test func fileSurvivesReopenAndSampleCannotOverwriteIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let workspace = try NativeWorkspace(path: path)
    try await workspace.createSample()
    _ = try await workspace.write(table: "notes", patch: ["title": .string("Persistent fixture")])
    await #expect(throws: Error.self) { try await workspace.createSample() }
    try await workspace.close()
    let reopened = try NativeWorkspace(path: path)
    #expect(try await reopened.rows(table: "notes", search: "Persistent fixture").count == 1)
    try await reopened.close()
    await #expect(throws: Error.self) { try await reopened.catalog() }
  }
}
