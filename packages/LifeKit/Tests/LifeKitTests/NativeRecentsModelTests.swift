import Foundation
import Testing

@testable import LifeKit

@MainActor
struct NativeRecentsModelTests {
  private func resolved(_ destination: NativeDestination, label: String = "Current label") throws -> NativeResolvedDestination {
    NativeResolvedDestination(
      destination: destination,
      catalog: try WorkspaceCatalog(CoreCatalog(tables: [], properties: [], rules: [])),
      view: nil,
      row: WorkspaceRow(record: ["id": .string(destination.rowID ?? "fixture")], label: label))
  }

  @Test func onlyExplicitNavigationCompletionRecordsAndRefreshDoesNotReorder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeRecentsStore(root: root, workspace: root.appendingPathComponent("local.sqlite"))
    _ = try store.load()
    let a = NativeDestination(table: "notes", rowID: "a")
    let b = NativeDestination(table: "notes", rowID: "b")
    _ = try store.update { _ in [b, a] }
    let before = try Data(contentsOf: store.file)
    var label = "First label"
    let model = NativeRecentsModel(store: store, resolve: { try resolved($0, label: label) })
    await model.refresh()
    #expect(model.destinations == [b, a])
    #expect(model.entries.map(\.label) == ["First label", "First label"])
    label = "Renamed label"
    await model.refresh()
    #expect(model.destinations == [b, a])
    #expect(model.entries.map(\.label) == ["Renamed label", "Renamed label"])
    #expect(try Data(contentsOf: store.file) == before)
    await model.navigationSucceeded(a)
    #expect(model.destinations == [a, b])
    #expect(try store.load() == [a, b])
  }

  @Test func sampleIsMemoryOnlyAndKeepsByteExactBoundedIdentities() async throws {
    let model = NativeRecentsModel(resolve: { try resolved($0) })
    await model.refresh()
    #expect(model.destinations.isEmpty && model.entries.isEmpty)
    for index in 0..<8 {
      await model.navigationSucceeded(NativeDestination(table: "notes", rowID: "\(index)"))
    }
    let composed = NativeDestination(table: "notes", rowID: "\u{00e9}")
    let decomposed = NativeDestination(table: "notes", rowID: "e\u{0301}")
    await model.navigationSucceeded(composed)
    await model.navigationSucceeded(decomposed)
    #expect(model.destinations.count == 8)
    #expect(model.destinations[0].rowID.map { Array($0.utf8) } == [101, 204, 129])
    #expect(model.destinations[1].rowID.map { Array($0.utf8) } == [195, 169])
    await model.remove(composed)
    #expect(model.destinations.count == 7 && model.destinations.first == decomposed)
    let nextSample = NativeRecentsModel(resolve: { try resolved($0) })
    await nextSample.refresh()
    #expect(nextSample.destinations.isEmpty)
  }

  @Test func unreadPreferencesRemainUntouchedWhileInMemoryNavigationAndRemovalWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeRecentsStore(root: root, workspace: root.appendingPathComponent("local.sqlite"))
    try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{\"version\":99,\"entries\":[]}".utf8)
    try bytes.write(to: store.file)
    let model = NativeRecentsModel(store: store, resolve: { try resolved($0) })
    #expect(model.storageError != nil)
    let destination = NativeDestination(table: "notes", rowID: "fixture")
    await model.navigationSucceeded(destination)
    #expect(model.destinations == [destination])
    #expect(model.entries.first?.label == "Current label")
    await model.remove(destination)
    #expect(model.destinations.isEmpty && model.entries.isEmpty)
    #expect(model.storageError != nil)
    #expect(try Data(contentsOf: store.file) == bytes)
  }

  @Test func writeFailureIsVisibleButDoesNotLoseTheCompletedNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeRecentsStore(root: root, workspace: root.appendingPathComponent("local.sqlite"))
    let model = NativeRecentsModel(store: store, resolve: { try resolved($0) })
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // A regular file in place of the preference directory creates a real I/O failure.
    try Data("fixture obstacle".utf8).write(to: store.file.deletingLastPathComponent())
    let destination = NativeDestination(table: "notes")
    await model.navigationSucceeded(destination)
    #expect(model.storageError != nil)
    #expect(model.destinations == [destination])
    #expect(model.entries.count == 1 && !model.entries[0].loading)
    try FileManager.default.removeItem(at: store.file.deletingLastPathComponent())
    let next = NativeDestination(table: "topics")
    await model.navigationSucceeded(next)
    #expect(model.destinations == [next, destination])
    #expect(model.storageError != nil)
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
  }

  @Test func unavailableEntriesRemainUntilExplicitRemovalAndCanRecover() async throws {
    var available = false
    let model = NativeRecentsModel(resolve: { destination in
      guard available else { throw WorkspaceError(message: "Outside this replica", violations: []) }
      return try resolved(destination)
    })
    let destination = NativeDestination(table: "notes", rowID: "fixture")
    await model.navigationSucceeded(destination)
    #expect(model.destinations == [destination])
    #expect(model.entries.first?.unavailable == "Outside this replica")
    #expect(model.entries.first?.loading == false)
    available = true
    await model.refresh()
    #expect(model.entries.first?.unavailable == nil)
    #expect(model.entries.first?.label == "Current label")
    await model.remove(destination)
    #expect(model.destinations.isEmpty)
  }

  @Test(arguments: ["refresh", "remove", "cancel", "workspace"])
  func lateResolutionCannotOverwriteNewerState(transition: String) async throws {
    var response: CheckedContinuation<NativeResolvedDestination, Error>?
    var held = false
    var current = true
    let destination = NativeDestination(table: "notes", rowID: "fixture")
    let model = NativeRecentsModel(resolve: { requested in
      if held { return try await withCheckedThrowingContinuation { response = $0 } }
      return try resolved(requested, label: "Fresh")
    }, isCurrent: { current })
    await model.navigationSucceeded(destination)
    held = true
    let pending = Task { await model.refresh() }
    while response == nil { await Task.yield() }
    held = false
    switch transition {
    case "refresh": await model.refresh()
    case "remove": await model.remove(destination)
    case "cancel": model.cancel()
    default: current = false
    }
    response?.resume(returning: try resolved(destination, label: "Obsolete"))
    await pending.value
    #expect(!model.entries.contains { $0.label == "Obsolete" })
    if transition == "refresh" { #expect(model.entries.first?.label == "Fresh") }
    if transition == "remove" || transition == "cancel" { #expect(model.entries.isEmpty) }
    if transition == "workspace" {
      await model.navigationSucceeded(NativeDestination(table: "wrong-workspace"))
      #expect(model.destinations == [destination])
    }
  }

  @Test func obsoleteErrorsDoNotReplaceResolvedEntries() async throws {
    var response: CheckedContinuation<NativeResolvedDestination, Error>?
    var held = false
    let destination = NativeDestination(table: "notes", rowID: "fixture")
    let model = NativeRecentsModel(resolve: { requested in
      if held { return try await withCheckedThrowingContinuation { response = $0 } }
      return try resolved(requested)
    })
    await model.navigationSucceeded(destination)
    held = true
    let pending = Task { await model.refresh() }
    while response == nil { await Task.yield() }
    held = false
    await model.refresh()
    response?.resume(throwing: WorkspaceError(message: "Old failure", violations: []))
    await pending.value
    #expect(model.entries.first?.label == "Current label")
    #expect(model.entries.first?.unavailable == nil)
  }

  @Test func cancelledRefreshCannotPublishItsLateReply() async throws {
    var response: CheckedContinuation<NativeResolvedDestination, Error>?
    var held = false
    let destination = NativeDestination(table: "notes", rowID: "fixture")
    let model = NativeRecentsModel(resolve: { requested in
      if held { return try await withCheckedThrowingContinuation { response = $0 } }
      return try resolved(requested)
    })
    await model.navigationSucceeded(destination)
    held = true
    let pending = Task { await model.refresh() }
    while response == nil { await Task.yield() }
    pending.cancel()
    response?.resume(returning: try resolved(destination, label: "Cancelled"))
    await pending.value
    #expect(!model.entries.contains { $0.label == "Cancelled" })
    #expect(model.destinations == [destination])
  }

  @Test func realCoreRefreshUsesFreshLabelsAndTrashWithoutWritingHistory() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let row = try await workspace.write(table: "notes", patch: [
      "title": .string("Original recent"), "body": .string("Full hidden Markdown"),
    ])
    let id = try #require(row["id"]?.text)
    let saved = try await workspace.saveView(CoreSaveViewArgs(
      table: "notes", name: "Original view", definition: CoreSavedViewDefinition(version: 1, columns: ["title"])))
    let resolver = NativeDestinationResolver(workspace: workspace)
    let model = NativeRecentsModel(resolve: { try await resolver.resolve($0, isCurrent: { true }) })
    let recordDestination = NativeDestination(table: "notes", viewID: saved.id, rowID: id)
    let viewDestination = NativeDestination(table: "notes", viewID: saved.id)
    // Resolving before the host has committed navigation must not remember anything.
    let fresh = try await resolver.resolve(recordDestination, isCurrent: { true })
    #expect(fresh.row?.record["body"] == .string("Full hidden Markdown"))
    await model.refresh()
    #expect(model.destinations.isEmpty)
    await model.navigationSucceeded(recordDestination)
    await model.navigationSucceeded(viewDestination)
    _ = try await workspace.write(table: "notes", patch: [
      "id": .string(id), "title": .string("Renamed recent"),
    ])
    _ = try await workspace.saveView(CoreSaveViewArgs(
      table: "notes", name: "Renamed view", definition: try #require(saved.definition),
      id: saved.id, expectedUpdatedAt: saved.updatedAt))
    await model.refresh()
    #expect(model.destinations == [viewDestination, recordDestination])
    #expect(model.entries.map(\.label) == ["Renamed view", "Renamed recent"])
    _ = try await workspace.write(table: "notes", patch: ["id": .string(id), "deleted_at": .bool(true)])
    await model.refresh()
    #expect(model.entries.last?.isTrashed == true)
    #expect(model.entries.last?.unavailable == nil)
    await model.navigationSucceeded(NativeDestination(table: "notes", rowID: "absent"))
    #expect(model.entries.first?.unavailable != nil)
    #expect(model.destinations.count == 3)
    runtime.context.evaluateScript("LifeSql.run(\"UPDATE catalog_tables SET kind='system' WHERE id='notes'\")")
    #expect(runtime.context.exception == nil)
    let system = try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true })
    #expect(system.catalog.tables.first { $0["id"] == .string("notes") }?["readOnly"] == .bool(true))
    try await workspace.close()
  }
}
