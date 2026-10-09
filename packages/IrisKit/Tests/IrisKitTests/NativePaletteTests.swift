import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct NativePaletteTests {
  private func catalog(_ tables: [String] = ["notes"]) throws -> WorkspaceCatalog {
    try WorkspaceCatalog(CoreCatalog(tables: tables.map { ["id": .string($0)] }, properties: [], rules: []))
  }

  private func view(_ table: String, name: String = "Saved") -> CoreSavedViewRecord {
    CoreSavedViewRecord(id: "view", name: name, tbl: table, updatedAt: "revision", deletedAt: nil,
      definition: CoreSavedViewDefinition(version: 1), view: CoreView(table: table), unavailable: nil)
  }

  @Test func realCoreMetadataUsesCurrentNamesAndExplicitRefresh() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let saved = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "First selection",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"], search: "absent")))
    let before = try await workspace.status()
    let model = NativePaletteModel(workspace: workspace)
    await model.load()
    #expect(!model.loading && model.error == nil)
    #expect(model.entries.contains { $0.destination == NativeDestination(table: "notes") })
    model.query = "  FIRST  "
    #expect(model.filteredEntries.map(\.label) == ["First selection"])
    #expect(model.filteredEntries.first?.destination == NativeDestination(table: "notes", viewID: saved.id))
    model.query = "notes"
    #expect(model.filteredEntries.map(\.label) == ["notes", "First selection"])
    #expect(try await workspace.status() == before)
    let renamed = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "Renamed selection",
      definition: CoreSavedViewDefinition(version: 1), id: saved.id, expectedUpdatedAt: saved.updatedAt))
    await model.refresh()
    #expect(model.filteredEntries.map(\.label) == ["notes", "Renamed selection"])
    _ = try await workspace.deleteView(CoreDeleteViewArgs(id: saved.id, expectedUpdatedAt: renamed.updatedAt!))
    await model.refresh()
    #expect(model.filteredEntries.map(\.label) == ["notes"])
    try await workspace.close()
  }

  @Test func realCorePreservesDistinctViewIDsAndUnavailableReasons() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      ["\u00e9", "e\u0301"].forEach((id, i) => {
        IrisSql.run("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,'notes',?)",
          [id, "Choice " + i, i ? '{"version":999}' : '{"version":1}']);
      });
      """#)
    #expect(runtime.context.exception == nil)
    let model = NativePaletteModel(workspace: workspace)
    await model.load()
    model.query = "choice"
    let entries = model.filteredEntries
    #expect(entries.count == 2 && Set(entries.map(\.id)).count == 2)
    #expect(entries.first { $0.label == "Choice 0" }?.unavailable == nil)
    #expect(entries.first { $0.label == "Choice 1" }?.unavailable?.isEmpty == false)
    #expect(Set(entries.compactMap { $0.destination.viewID.map { Data($0.utf8) } })
      == [Data([0xc3, 0xa9]), Data([0x65, 0xcc, 0x81])])
    try await workspace.close()
  }

  @Test func progressivePartialResultsFilterLocallyAndRetryExplicitly() async throws {
    var held: CheckedContinuation<CoreSavedViewList, Error>?
    var tablesRead: [String] = []
    var catalogReads = 0
    var retry = false
    let model = NativePaletteModel(catalog: {
      catalogReads += 1
      return try catalog(["alpha", "beta", "gamma"])
    }, listViews: { table in
      tablesRead.append(table)
      if retry { return CoreSavedViewList(views: [], unavailable: nil) }
      if table == "beta" { return try await withCheckedThrowingContinuation { held = $0 } }
      return CoreSavedViewList(views: [view(table, name: "Selection " + table)],
        unavailable: table == "alpha" ? "Partial metadata" : nil)
    })
    let pending = Task { await model.load() }
    while held == nil { await Task.yield() }
    #expect(model.loading)
    #expect(model.entries.map(\.label) == ["alpha", "beta", "gamma", "Selection alpha"])
    #expect(model.error == "alpha: Partial metadata")
    model.query = "  SELECTION  "
    #expect(model.filteredEntries.map(\.label) == ["Selection alpha"])
    model.query = "alpha"
    #expect(model.filteredEntries.map(\.label) == ["alpha", "Selection alpha"])
    await model.load()
    #expect(tablesRead == ["alpha", "beta"] && catalogReads == 1)
    held?.resume(throwing: WorkspaceError(message: "Read failed", violations: []))
    await pending.value
    #expect(!model.loading && tablesRead == ["alpha", "beta", "gamma"])
    #expect(model.error == "alpha: Partial metadata\nbeta: Read failed")
    model.query = ""
    #expect(model.filteredEntries.map(\.label) == ["alpha", "beta", "gamma", "Selection alpha", "Selection gamma"])
    model.query = "missing"
    #expect(model.filteredEntries.isEmpty)
    await model.load()
    #expect(tablesRead.count == 3 && catalogReads == 1)
    retry = true
    await model.refresh()
    #expect(!model.loading && model.error == nil)
    #expect(model.entries.map(\.label) == ["alpha", "beta", "gamma"])
    #expect(catalogReads == 2 && tablesRead.count == 6)
  }

  @Test(arguments: ["table", "tombstone", "unavailable", "definition", "query"])
  func unavailableMetadataRemainsVisibleButDisabled(_ invalid: String) async throws {
    var saved = view("notes")
    switch invalid {
    case "table": saved.tbl = "other"
    case "tombstone": saved.deletedAt = "deleted"
    case "unavailable": saved.unavailable = "Core reason"
    case "definition": saved.definition = nil
    default: saved.view = nil
    }
    let model = NativePaletteModel(catalog: { try catalog() }, listViews: { _ in
      CoreSavedViewList(views: [saved], unavailable: nil)
    })
    await model.load()
    let entry = try #require(model.entries.last)
    #expect(model.entries.count == 2 && entry.label == "Saved")
    #expect(entry.unavailable?.isEmpty == false)
    if invalid == "unavailable" { #expect(entry.unavailable == "Core reason") }
  }

  @Test func catalogFailureCanBeRetriedAndClosedModelsNeverRead() async throws {
    var reads = 0
    var current = false
    let model = NativePaletteModel(catalog: {
      reads += 1
      if reads == 1 { throw WorkspaceError(message: "Catalog failed", violations: []) }
      return try catalog([])
    }, listViews: { _ in Issue.record("Empty catalog must not read views"); return CoreSavedViewList(views: [], unavailable: nil) },
      isCurrent: { current })
    await model.load()
    #expect(reads == 0 && !model.loading)
    current = true
    await model.load()
    #expect(model.error == "Catalog failed" && !model.loading && model.entries.isEmpty)
    await model.load()
    #expect(reads == 1)
    await model.refresh()
    #expect(model.error == nil && !model.loading && reads == 2)
    model.dispose()
    await model.load()
    await model.refresh()
    #expect(model.entries.isEmpty && model.error == nil && !model.loading && reads == 2)
  }

  @Test(arguments: ["catalog", "views"], [false, true])
  func obsoleteRepliesCannotPublishOrContinueReads(_ boundary: String, fails: Bool) async throws {
    for ending in ["refresh", "dispose", "workspace", "cancel"] {
      var held: CheckedContinuation<Void, Error>?
      var isOld = true
      var current = true
      var reads: [String] = []
      func checkpoint(_ stage: String) async throws {
        reads.append(stage)
        if isOld && boundary == stage {
          try await withCheckedThrowingContinuation { held = $0 }
        }
      }
      let model = NativePaletteModel(catalog: {
        let old = isOld
        try await checkpoint("catalog")
        return try catalog(old ? ["alpha", "beta"] : ["current"])
      }, listViews: { table in
        try await checkpoint("views")
        return CoreSavedViewList(views: [view(table)], unavailable: "Obsolete warning")
      }, isCurrent: { current })
      let pending = Task { await model.load() }
      while held == nil { await Task.yield() }
      isOld = false
      switch ending {
      case "refresh": await model.refresh()
      case "dispose": model.dispose()
      case "workspace": current = false
      default: pending.cancel()
      }
      let expected = model.entries.map(\.destination)
      let expectedError = model.error
      let readsBeforeReply = reads
      if fails { held?.resume(throwing: WorkspaceError(message: "Obsolete failure", violations: [])) }
      else { held?.resume() }
      await pending.value
      #expect(model.entries.map(\.destination) == expected && model.error == expectedError)
      #expect(reads == readsBeforeReply && !model.loading)
      if ending == "refresh" { #expect(model.entries.first?.destination.table == "current") }
    }
  }

  @Test func olderCompletionDoesNotClearTheNewLoadingState() async throws {
    var held: [CheckedContinuation<WorkspaceCatalog, Error>] = []
    let model = NativePaletteModel(catalog: {
      try await withCheckedThrowingContinuation { held.append($0) }
    }, listViews: { _ in CoreSavedViewList(views: [], unavailable: nil) })
    let first = Task { await model.load() }
    while held.count < 1 { await Task.yield() }
    let second = Task { await model.refresh() }
    while held.count < 2 { await Task.yield() }
    held[0].resume(throwing: WorkspaceError(message: "Old failure", violations: []))
    await first.value
    #expect(model.loading && model.error == nil && model.entries.isEmpty)
    held[1].resume(returning: try catalog(["current"]))
    await second.value
    #expect(!model.loading && model.entries.map(\.label) == ["current"])
  }

  @Test func alreadyCancelledTaskDoesNotStartDiscovery() async throws {
    var reads = 0
    let model = NativePaletteModel(catalog: {
      reads += 1
      return try catalog([])
    }, listViews: { _ in CoreSavedViewList(views: [], unavailable: nil) })
    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await model.load()
      await model.refresh()
    }.value
    #expect(reads == 0 && !model.loading)
    await model.load()
    #expect(reads == 1)
  }
}
