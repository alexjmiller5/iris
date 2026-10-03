import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct IncomingReferencesTests {
  @Test func realCoreKeepsCanonicallyEquivalentSQLiteIDsDistinct() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    let ids = ["\u{00E9}", "e\u{0301}"]
    runtime.context.setObject(ids, forKeyedSubscript: "incomingIDs" as NSString)
    runtime.context.setObject(topic.id, forKeyedSubscript: "incomingTarget" as NSString)
    runtime.context.evaluateScript(
      #"incomingIDs.forEach((id, i) => LifeSql.run("INSERT INTO notes(id,title,topic) VALUES (?,?,?)", [id, "Distinct " + i, incomingTarget]))"#)
    #expect(runtime.context.exception == nil)
    let page = try await workspace.referencedBy(CoreReferencedByArgs(
      table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic"))
    #expect(page.rows.count == 2)
    #expect(Set(page.rows.map { Data($0.id.utf8) }) == Set(ids.map { Data($0.utf8) }))
    #expect(Set(page.rows.map(\.byteExactID)).count == 2)
    let model = IncomingReferencesModel(
      table: "topics", rowID: topic.id,
      readSources: { try await workspace.referenceSources($0) },
      readPage: { try await workspace.referencedBy($0) })
    await model.refresh()
    let id = try #require(model.groups.first { $0.source.column == "topic" }?.id)
    await model.load(id)
    let rows = try #require(model.groups.first { $0.id == id }?.rows)
    #expect(rows.count == 2)
    #expect(Set(rows.map { Data($0.id.utf8) }) == Set(ids.map { Data($0.utf8) }))
    #expect(Set(rows.map(\.label)) == ["Distinct 0", "Distinct 1"])
    try await workspace.close()
  }

  @Test(arguments: ["notes", "topics"])
  func realCoreCompletenessSurvivesOfflineReopenForSkippedSourceOrTarget(_ skipped: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try LifeCoreRuntime()
    let path = root.appendingPathComponent("incoming.sqlite").path
    let workspace = try NativeWorkspace(path: path, runtime: runtime)
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    let note = try await workspace.write(
      table: "notes", patch: ["title": .string("Cached link"), "topic": .string(topic.id)])
    _ = try await workspace.status()
    runtime.context.setObject(skipped, forKeyedSubscript: "incomingSkipped" as NSString)
    runtime.context.evaluateScript(
      #"LifeSql.run("INSERT OR REPLACE INTO _core_state(key,value) VALUES ('skipped_tables',?)", [JSON.stringify([incomingSkipped])])"#)
    #expect(runtime.context.exception == nil)
    try await workspace.close()
    let reopened = try NativeWorkspace(path: path)
    let sources = try await reopened.referenceSources(CoreReferenceSourcesArgs(table: "topics"))
    #expect(sources.count == 2 && sources.allSatisfy(\.incomplete))
    let page = try await reopened.referencedBy(CoreReferencedByArgs(
      table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic"))
    #expect(page.source.incomplete)
    #expect(page.rows.first?.record == note)
    #expect(try await reopened.status().skippedTables == [skipped])
    try await reopened.close()
  }

  @Test func realCoreMetadataAndPagesKeepFullRowsLabelsAndLiveSources() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    var expected: Set<String> = []
    for index in 0..<23 {
      let row = try await workspace.write(
        table: "notes", patch: [
          "title": .string("Incoming \(index)"), "body": .string("Full body \(index)"),
          "topic": .string(topic.id),
        ])
      let id = try #require(row["id"])
      if index == 22 {
        _ = try await workspace.write(table: "notes", patch: ["id": id, "deleted_at": .bool(true)])
      } else { expected.insert(id.text) }
    }
    let sources = try await workspace.referenceSources(CoreReferenceSourcesArgs(table: "topics"))
    #expect(Set(sources.map(\.column)) == ["topic", "related"])
    #expect(sources.allSatisfy { $0.table == "notes" && !$0.incomplete })
    #expect(sources.first { $0.column == "topic" }?.label == "Topic")
    let page = try await workspace.referencedBy(
      CoreReferencedByArgs(table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic"))
    #expect(page.rows.count == 20)
    #expect(page.nextOffset == 20)
    #expect(page.rows.allSatisfy { $0.record["body"]?.text.hasPrefix("Full body ") == true })
    #expect(page.rows.allSatisfy { $0.label == $0.record["title"]?.text })
    let next = try await workspace.referencedBy(
      CoreReferencedByArgs(
        table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic", offset: 20))
    #expect(next.rows.count == 2 && next.nextOffset == nil)
    #expect(Set((page.rows + next.rows).map(\.id)) == expected)
    // Incoming links remain inspectable after the target is trashed.
    _ = try await workspace.write(
      table: "topics", patch: ["id": .string(topic.id), "deleted_at": .bool(true)])
    #expect(
      try await workspace.referencedBy(
        CoreReferencedByArgs(table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic")
      ).rows.count == 20)
    #expect(
      try await workspace.referencedBy(
        CoreReferencedByArgs(table: "topics", rowId: "missing", sourceTable: "notes", column: "topic")
      ).rows.isEmpty)
    try await workspace.close()
  }

  @Test func realCoreMultiReferencesIgnoreMalformedJSONAndKeepDeprecatedLiveFields() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let topic = try #require(try await workspace.rows(table: "topics").first)
    runtime.context.setObject(topic.id, forKeyedSubscript: "incomingTarget" as NSString)
    runtime.context.evaluateScript(
      #"""
      LifeSql.run("INSERT INTO notes(id,title,related) VALUES ('repeat','Repeated',?),('broken','Broken','['),('object','Object','{}')", [JSON.stringify([incomingTarget, incomingTarget])]);
      LifeSql.run("UPDATE catalog_properties SET deprecated=1 WHERE id='notes.related'");
      """#)
    #expect(runtime.context.exception == nil)
    let sources = try await workspace.referenceSources(CoreReferenceSourcesArgs(table: "topics"))
    #expect(sources.contains { $0.column == "related" && $0.type == "multi_ref" })
    let page = try await workspace.referencedBy(
      CoreReferencedByArgs(table: "topics", rowId: topic.id, sourceTable: "notes", column: "related"))
    #expect(page.rows.map(\.id) == ["repeat"])
    #expect(page.rows.first?.label == "Repeated")
    #expect(page.nextOffset == nil)
    try await workspace.close()
  }
}
