import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct LocalViewsTests {
  private func fixtureSQL(_ file: URL, _ script: String) throws -> String? {
    let context = try #require(JSContext())
    let database = try SQLiteBridge(path: file.path)
    defer { try? database.close() }
    try database.install(in: context)
    let result = context.evaluateScript(script)
    try #require(
      context.exception == nil, Comment(rawValue: context.exception?.toString() ?? "SQL failed"))
    return result?.toString()
  }

  private func legacyDatabase(_ file: URL) async throws {
    let workspace = try NativeWorkspace(path: file.path)
    try await workspace.createSample()
    _ = try await workspace.write(table: "notes", patch: ["title": .string("Preserved local note")])
    try await workspace.close()
    _ = try fixtureSQL(
      file,
      """
      LifeSql.run('DROP TRIGGER IF EXISTS views_updated_at');
      LifeSql.run('DROP TABLE views');
      LifeSql.run("DELETE FROM catalog_tables WHERE id='views'");
      LifeSql.run("DELETE FROM catalog_properties WHERE tbl='views'");
      """)
  }

  @Test func nativeHostBackfillsLegacyLocalSchemaAndIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    try await legacyDatabase(file)
    let workspace = try NativeWorkspace(path: file.path)
    let before = try await workspace.rows(table: "notes")
    #expect(try await workspace.prepareLocalViews())
    #expect(try await workspace.catalog().tables.contains { $0["id"] == .string("views") })
    #expect(try await workspace.rows(table: "notes") == before)
    #expect(try await !workspace.prepareLocalViews())
    try await workspace.close()
  }

  @Test func openingOnlyAppOwnedLocalDatabasePreparesViews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local.sqlite")
    let external = root.appendingPathComponent("external.sqlite")
    try await legacyDatabase(local)
    try await legacyDatabase(external)
    let model = WorkspaceModel(localURL: { local })
    await model.open(url: external)
    #expect(model.error == nil)
    #expect(!model.tables.contains { $0["id"] == .string("views") })
    await model.close()
    await model.open()
    #expect(model.error == nil)
    #expect(model.tables.contains { $0["id"] == .string("views") })
    #expect(model.rows.contains { $0.label == "Preserved local note" })
    await model.close()
  }

  @Test func openingOwnedDatabaseLeavesNameCollisionUntouched() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    try await legacyDatabase(file)
    _ = try fixtureSQL(
      file,
      """
      LifeSql.run('CREATE TABLE views (id TEXT, payload TEXT)');
      LifeSql.run("INSERT INTO views VALUES ('fixture','Preserve this')");
      """)
    let model = WorkspaceModel(localURL: { file })
    await model.open()
    #expect(model.error == nil)
    #expect(!model.tables.contains { $0["id"] == .string("views") })
    await model.close()
    #expect(
      try fixtureSQL(file, "LifeSql.all('SELECT payload FROM views')[0].payload") == "Preserve this"
    )
  }
}
