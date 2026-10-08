import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct WorkspaceDestinationTests {
  @Test func freshViewAndTableActivationReplaceSameTableSettings() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let client = try #require(model.client)
    model.table = "notes"
    let context = try #require(model.editingContext)
    let saved = try await client.saveView(CoreSaveViewArgs(table: "notes", name: "Original",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"],
        filters: [CoreFilter(column: "status", op: .eq, value: .string("Draft"))],
        sort: [CoreSort(column: "title", direction: .desc)], search: "original")))
    try model.applySavedView(saved, context: context)
    let renamed = try await client.saveView(CoreSaveViewArgs(table: "notes", name: "Fresh name",
      definition: CoreSavedViewDefinition(version: 1, columns: ["status"],
        sort: [CoreSort(column: "title", direction: .asc)], search: "fresh", trash: true),
      id: saved.id, expectedUpdatedAt: saved.updatedAt))
    let resolver = NativeDestinationResolver(workspace: client)
    let view = try await resolver.resolve(NativeDestination(table: "notes", viewID: saved.id), isCurrent: { true })
    let installed = try model.activateDestination(view, workspace: client, generation: model.workspaceGeneration)
    #expect(installed.workspace === client && installed.table == "notes")
    #expect(model.appliedView == renamed && model.search == "fresh" && model.trash)
    #expect(model.filters.isEmpty && model.sortAscending)
    #expect(model.catalog?.properties == view.catalog.properties)
    model.search = "unsaved view search"
    model.filters = [WorkspaceFilter(column: "title", operation: .contains, value: "unsaved")]
    let table = try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true })
    _ = try model.activateDestination(table, workspace: client, generation: model.workspaceGeneration)
    #expect(model.table == "notes" && model.appliedView?.name == "Default view")
    #expect(model.search.isEmpty && !model.trash)
    #expect(model.filters.isEmpty && model.sortRules.isEmpty)
    await model.close()
  }

  @Test func freshCatalogAndFullTombstoneCanBeInstalledWithoutCachedTableMetadata() async throws {
    let runtime = try LifeCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    runtime.context.evaluateScript(
      #"""
      LifeSql.run(`CREATE TABLE added (id TEXT PRIMARY KEY, title TEXT, body TEXT, deleted_at TEXT)`);
      LifeSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('added','table','title')");
      LifeSql.run("INSERT INTO added VALUES ('row','Fresh target','Complete hidden body','deleted')");
      """#)
    #expect(runtime.context.exception == nil)
    #expect(!model.tables.contains { $0["id"] == .string("added") })
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(
      NativeDestination(table: "added", rowID: "row"), isCurrent: { true })
    let context = try model.activateDestination(resolved, workspace: client, generation: model.workspaceGeneration)
    #expect(context.table == "added" && model.table == "added" && model.trash)
    #expect(model.tables.contains { $0["id"] == .string("added") })
    #expect(resolved.row?.record["body"] == .string("Complete hidden body"))
    #expect(model.appliedView == nil)
    await model.close()
  }

  @Test func aClosedOrReplacedWorkspaceCannotInstallResolvedState() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let client = try #require(model.client)
    let generation = model.workspaceGeneration
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(
      NativeDestination(table: "topics"), isCurrent: { true })
    model.search = "Keep current search"
    let originalQuery = model.queryKey
    #expect(throws: WorkspaceError.self) {
      try model.activateDestination(resolved, workspace: client, generation: generation - 1)
    }
    #expect(model.queryKey == originalQuery)
    let other = try NativeWorkspace(path: ":memory:")
    try await other.createSample()
    #expect(throws: WorkspaceError.self) {
      try model.activateDestination(resolved, workspace: other, generation: generation)
    }
    #expect(model.queryKey == originalQuery)
    try await other.close()
    await model.open(demo: true)
    model.table = "notes"
    model.search = "Preserved newer query"
    let before = model.queryKey
    #expect(throws: WorkspaceError.self) {
      try model.activateDestination(resolved, workspace: client, generation: generation)
    }
    #expect(model.queryKey == before && model.table == "notes")
    await model.close()
    #expect(throws: WorkspaceError.self) {
      try model.activateDestination(resolved, workspace: client, generation: generation)
    }
    #expect(model.client == nil && model.catalog == nil)
  }

  @Test(arguments: ["write", "undo", "saveView"])
  func busyOperationsRejectNavigationBeforeMutatingWorkspace(_ operation: String) async throws {
    let runtime = try LifeCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    _ = try await model.save(["title": .string("Before")], original: nil, context: context)
    let action = try #require(model.undoAction)
    model.search = "Retain this query"
    let destination = try await NativeDestinationResolver(workspace: client).resolve(
      NativeDestination(table: "topics"), isCurrent: { true })
    let before = model.queryKey
    let beforeCatalog = model.catalog?.tables
    runtime.context.evaluateScript(
      "var originalRequest = LifeNative.request; var heldNavigation = null; LifeNative.request = (id,method,args) => { if(method === '\(operation)') heldNavigation = [id,method,args]; else originalRequest(id,method,args); };"
    )
    var finished = false
    let pending = Task {
      defer { finished = true }
      switch operation {
      case "write": _ = try await model.save(["title": .string("Pending")], original: nil, context: context)
      case "undo": _ = try await model.undo(action, context: context)
      default: try await model.saveCurrentView(name: "Pending view", update: false, context: context)
      }
    }
    while !finished && runtime.context.evaluateScript("heldNavigation === null")?.toBool() == true {
      await Task.yield()
    }
    #expect(!finished)
    #expect(throws: WorkspaceError.self) {
      try model.activateDestination(destination, workspace: client, generation: model.workspaceGeneration)
    }
    #expect(model.table == "notes" && model.queryKey == before && model.catalog?.tables == beforeCatalog)
    runtime.context.evaluateScript(
      "LifeNative.request = originalRequest; if (heldNavigation) originalRequest(...heldNavigation);")
    try await pending.value
    _ = try model.activateDestination(destination, workspace: client, generation: model.workspaceGeneration)
    #expect(model.table == "topics")
    await model.close()
  }
}
