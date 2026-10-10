import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct IncomingReferencesContextTests {
  @Test func panelContextUsesExactRecordIDBytes() async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    let composed = "\u{00E9}", decomposed = "e\u{0301}"
    runtime.context.setObject([composed, decomposed], forKeyedSubscript: "incomingIDs" as NSString)
    runtime.context.evaluateScript(
      #"""
      incomingIDs.forEach((id, i) => {
        IrisSql.run("INSERT INTO topics(id,title) VALUES (?,?)", [id, "Target " + i]);
        IrisSql.run("INSERT INTO notes(id,title,topic) VALUES (?,?,?)", ["source-" + i, "Source " + i, id]);
      });
      """#)
    #expect(runtime.context.exception == nil)
    host.table = "topics"
    let context = try #require(host.editingContext)
    let row: WorkspaceRecord = ["id": .string(composed)]
    let first = try #require(host.incomingReferencesIdentity(context: context, row: row))
    let second = try #require(host.incomingReferencesIdentity(
      context: context, row: ["id": .string(decomposed)]))
    #expect(Set([first, second]).count == 2)
    for (index, id) in [composed, decomposed].enumerated() {
      let panel = try #require(host.makeIncomingReferences(
        context: context, row: ["id": .string(id)]))
      await panel.refresh()
      let group = try #require(panel.groups.first { $0.source.column == "topic" }?.id)
      await panel.load(group)
      let rows = try #require(panel.groups.first { $0.id == group }?.rows)
      #expect(rows.map(\.label) == ["Source \(index)"])
      #expect(rows.first?.record["topic"].map { Data($0.text.utf8) } == Data(id.utf8))
    }
    await host.close()
  }

  @Test(arguments: ["tableRoundTrip", "editorClosed", "workspaceRoundTrip"])
  func replacedHostContextCannotReactivateAnOldPanel(_ transition: String) async throws {
    let client = try NativeWorkspace(path: ":memory:")
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    host.catalog = try await client.catalog()
    host.table = "topics"
    let context = try #require(host.editingContext)
    let row = try #require(try await client.rows(table: "topics").first?.record)
    var editorCurrent = true
    let panel = try #require(host.makeIncomingReferences(
      context: context, row: row, isCurrent: { editorCurrent }))
    await panel.refresh()
    let id = try #require(panel.groups.first?.id)
    switch transition {
    case "tableRoundTrip":
      host.table = "notes"
      host.table = "topics"
    case "workspaceRoundTrip":
      host.client = nil
      host.client = client
    default: editorCurrent = false
    }
    await panel.load(id)
    #expect(panel.groups.first?.loaded == false)
    #expect(panel.groups.first?.error == nil)
    await host.close()
  }

  @Test func onlyASavedRecordInTheCurrentContextGetsAnIncomingModel() async throws {
    let client = try NativeWorkspace(path: ":memory:")
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    host.catalog = try await client.catalog()
    host.table = "topics"
    let context = try #require(host.editingContext)
    let row = try #require(try await client.rows(table: "topics").first?.record)
    #expect(host.makeIncomingReferences(context: context, row: nil) == nil)
    #expect(host.incomingReferencesIdentity(context: context, row: nil) == nil)
    let panel = try #require(host.makeIncomingReferences(context: context, row: row))
    await panel.refresh()
    #expect(panel.groups.count == 2)
    let tombstone = try await client.write(
      table: "topics", patch: ["id": row["id"]!, "deleted_at": .bool(true)])
    #expect(host.makeIncomingReferences(context: context, row: tombstone) != nil)
    host.table = "notes"
    #expect(host.makeIncomingReferences(context: context, row: row) == nil)
    await panel.refresh()
    #expect(panel.groups.count == 2, "An obsolete panel must not reload for the new table")
    await host.close()
    #expect(host.makeIncomingReferences(context: context, row: row) == nil)
  }

  @Test func panelIdentityIgnoresSavedBodyRevisionsAndStatusCountsButTracksCoverage() async throws {
    let client = try NativeWorkspace(path: ":memory:")
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    host.catalog = try await client.catalog()
    host.table = "notes"
    let context = try #require(host.editingContext)
    let row = try #require(try await client.rows(table: "notes").first?.record)
    host.isReplica = true
    host.syncStatus = CoreSyncStatus(
      lastSuccessfulSync: nil, pendingUiEdits: 0, rejected: 0, skippedTables: [])
    let identity = try #require(host.incomingReferencesIdentity(context: context, row: row))
    let saved = try await client.write(
      table: "notes", patch: ["id": row["id"]!, "body": .string("An ordinary body save")])
    host.catalog = try await client.catalog()
    host.syncStatus = CoreSyncStatus(
      lastSuccessfulSync: "2026-01-01", pendingUiEdits: 7, rejected: 2, skippedTables: [])
    let afterSave = try #require(host.incomingReferencesIdentity(context: context, row: saved))
    #expect(Set([identity, afterSave]).count == 1)
    host.syncStatus?.skippedTables = ["notes", "topics"]
    let partial = try #require(host.incomingReferencesIdentity(context: context, row: saved))
    #expect(partial != identity)
    host.syncStatus?.skippedTables = ["topics", "notes"]
    #expect(host.incomingReferencesIdentity(context: context, row: saved) == partial)
    host.syncStatus?.skippedTables = []
    #expect(host.incomingReferencesIdentity(context: context, row: saved) == identity)
    let other = try #require(try await client.rows(table: "topics").first?.record)
    #expect(host.incomingReferencesIdentity(context: context, row: other) != identity)
    host.client = nil
    host.client = client
    #expect(host.incomingReferencesIdentity(context: context, row: saved) != identity)
    await host.close()
  }

  @Test(arguments: ["label", "delete", "target"])
  func catalogChangesInvalidateOnlyTheIncomingContextWhileDraftValuesStayPinned(_ change: String) async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    host.catalog = try await client.catalog()
    host.table = "topics"
    let context = try #require(host.editingContext)
    let row = try #require(try await client.rows(table: "topics").first?.record)
    let editor = RecordEditorModel(
      properties: host.properties, original: row, table: "topics", store: nil
    ) { _, _ in
      Issue.record("Refreshing incoming references must never write the draft")
      return row
    }
    editor.setValue("Keep this raw draft", for: "title")
    let identity = try #require(host.incomingReferencesIdentity(context: context, row: row))
    let old = try #require(host.makeIncomingReferences(context: context, row: row))
    await old.refresh()
    let source = try #require(old.groups.first { $0.source.column == "topic" })
    let sql = switch change {
    case "label": "UPDATE catalog_properties SET label='Renamed source' WHERE id='notes.topic'"
    case "delete": "UPDATE catalog_properties SET deleted_at='2026-01-01' WHERE id='notes.topic'"
    default: "UPDATE catalog_properties SET ref_table='notes' WHERE id='notes.topic'"
    }
    runtime.context.setObject(sql, forKeyedSubscript: "incomingMetadataChange" as NSString)
    runtime.context.evaluateScript("IrisSql.run(incomingMetadataChange)")
    #expect(runtime.context.exception == nil)
    host.catalog = try await client.catalog()
    #expect(host.incomingReferencesIdentity(context: context, row: row) != identity)
    // Reject calls even before SwiftUI has disposed the old child.
    await old.refresh()
    await old.load(source.id)
    #expect(old.groups.first { $0.id == source.id }?.source.label == "Topic")
    #expect(old.groups.first { $0.id == source.id }?.loaded == false)
    let fresh = try #require(host.makeIncomingReferences(context: context, row: row))
    await fresh.refresh()
    if change == "label" {
      #expect(fresh.groups.first { $0.id == source.id }?.source.label == "Renamed source")
    } else {
      #expect(!fresh.groups.contains { $0.id == source.id })
    }
    #expect(editor.draft.values["title"] == "Keep this raw draft" && editor.dirty)
    #expect(editor.draft.original == row)
    await host.close()
  }

  @Test func incomingSelectionUsesFreshReferenceNavigationAndPreservesACancelledDraft() async throws {
    let client = try NativeWorkspace(path: ":memory:")
    try await client.createSample()
    let host = WorkspaceModel()
    host.client = client
    host.catalog = try await client.catalog()
    host.table = "topics"
    let context = try #require(host.editingContext)
    let target = try #require(try await client.rows(table: "topics").first)
    let note = try await client.write(
      table: "notes", patch: ["title": .string("Cached label"), "topic": .string(target.id)])
    let panel = try #require(host.makeIncomingReferences(context: context, row: target.record))
    await panel.refresh()
    let id = try #require(panel.groups.first { $0.source.column == "topic" }?.id)
    await panel.load(id)
    let link = try #require(panel.groups.first { $0.id == id }?.rows.first)
    #expect(link.label == "Cached label")
    let editor = RecordEditorModel(
      properties: host.properties, original: target.record, table: "topics", store: nil
    ) { _, _ in
      // Leaving saves first; a refused save leaves a draft that must be confirmed away.
      throw WorkspaceError(message: "Synthetic refusal", violations: [])
    }
    editor.setValue("Retain until approved", for: "title")
    let navigation = host.makeReferenceNavigation(editor: editor, context: context)
    #expect(await navigation.open(table: id.table, id: link.id) == nil)
    #expect(navigation.confirmation != nil)
    navigation.cancel()
    #expect(editor.draft.values["title"] == "Retain until approved")
    _ = await navigation.open(table: id.table, id: link.id)
    let updated = try await client.write(
      table: "notes", patch: ["id": note["id"]!, "body": .string("Fresh complete body")])
    let opened = try #require(await navigation.discardAndOpen())
    #expect(opened.table == "notes" && opened.row.record == updated)
    #expect(opened.row.record["body"] == .string("Fresh complete body"))
    await host.close()
  }
}
