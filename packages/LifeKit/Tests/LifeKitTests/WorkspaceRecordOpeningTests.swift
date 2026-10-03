import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct WorkspaceRecordOpeningTests {
  @Test(arguments: [false, true])
  func openingAListRowRefreshesDataWithoutResettingItsModifiedView(trashed: Bool) async throws {
    let runtime = try LifeCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let original = try #require(try await client.rows(table: "notes").first)
    let saved = try await client.saveView(CoreSaveViewArgs(table: "notes", name: "Selected view",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"], search: "saved")))
    try model.applySavedView(saved, context: context)
    model.search = "Unsaved search"
    model.sortColumn = "title"
    model.sortAscending = false
    model.filters = [WorkspaceFilter(column: "status", operation: .eq, value: "Draft")]
    let before = model.queryKey
    #expect(model.viewModified)
    let stored = try await client.write(table: "notes", patch: [
      "id": .string(original.id), "body": .string("Fresh hidden Markdown"),
      "deleted_at": trashed ? .bool(true) : .null,
    ], expectedUpdatedAt: original.record["updated_at"]?.text)
    runtime.context.evaluateScript("LifeSql.run(\"UPDATE catalog_tables SET purpose='Current purpose' WHERE id='notes'\")")
    #expect(runtime.context.exception == nil)
    let destination = NativeDestination(table: "notes", rowID: original.id)
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(destination, isCurrent: { true })
    let opened = try model.refreshedRecordContext(resolved, workspace: client, generation: model.workspaceGeneration)
    #expect(opened.workspace === client && opened.table == "notes")
    #expect(resolved.row?.record == stored)
    #expect(resolved.isTrashed == trashed && !model.trash)
    #expect(model.queryKey == before && model.appliedView == saved && model.viewModified)
    #expect(model.visibleRecordColumns == ["title"])
    #expect(model.tables.first { $0["id"] == .string("notes") }?["purpose"] == .string("Current purpose"))
    await model.close()
  }

  @Test func delayedListRowCannotInstallIntoAChangedTableOrWorkspace() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let client = try #require(model.client)
    let generation = model.workspaceGeneration
    let id = try #require(model.rows.first?.id)
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(
      NativeDestination(table: "notes", rowID: id), isCurrent: { true })
    model.table = "topics"
    model.search = "Keep topics"
    let query = model.queryKey
    #expect(throws: WorkspaceError.self) {
      try model.refreshedRecordContext(resolved, workspace: client, generation: generation)
    }
    #expect(model.queryKey == query)
    await model.open(demo: true)
    let before = model.queryKey
    #expect(throws: WorkspaceError.self) {
      try model.refreshedRecordContext(resolved, workspace: client, generation: generation)
    }
    #expect(model.queryKey == before)
    await model.close()
  }

  @Test func pendingRecordWritePreventsListRowInstallation() async throws {
    let runtime = try LifeCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let id = try #require(try await client.rows(table: "notes").first?.id)
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(
      NativeDestination(table: "notes", rowID: id), isCurrent: { true })
    runtime.context.evaluateScript("var requestBefore = LifeNative.request; var heldRecordOpen = null; LifeNative.request = (id,method,args) => { if(method === 'write') heldRecordOpen = [id,method,args]; else requestBefore(id,method,args); };")
    var finished = false
    let pending = Task {
      defer { finished = true }
      _ = try await model.save(["title": .string("Pending")], original: nil, context: context)
    }
    while !finished && runtime.context.evaluateScript("heldRecordOpen === null")?.toBool() == true { await Task.yield() }
    #expect(!finished)
    let query = model.queryKey
    #expect(throws: WorkspaceError.self) {
      try model.refreshedRecordContext(resolved, workspace: client, generation: model.workspaceGeneration)
    }
    #expect(model.queryKey == query)
    runtime.context.evaluateScript("LifeNative.request = requestBefore; if (heldRecordOpen) requestBefore(...heldRecordOpen);")
    try await pending.value
    _ = try model.refreshedRecordContext(resolved, workspace: client, generation: model.workspaceGeneration)
    await model.close()
  }
}
