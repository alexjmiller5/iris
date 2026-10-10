import Foundation
import Testing

@testable import IrisKit

@MainActor
struct QuickFindCoordinatorTests {
  private func waitForRequest(_ arrived: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if arrived() { return }
      await Task.yield()
    }
    try #require(arrived(), "The controlled request never started")
  }

  private func catalog(_ tables: [String] = ["notes"]) throws -> WorkspaceCatalog {
    try WorkspaceCatalog(
      CoreCatalog(tables: tables.map { ["id": .string($0)] }, properties: [], rules: []))
  }

  private func view(_ id: String, name: String = "Choice", unavailable: String? = nil)
    -> CoreSavedViewRecord
  {
    CoreSavedViewRecord(
      id: id, name: name, tbl: "notes", updatedAt: "revision", deletedAt: nil,
      definition: CoreSavedViewDefinition(version: 1), view: CoreView(table: "notes"),
      unavailable: unavailable)
  }

  private func hit(_ id: String, table: String = "notes") -> CoreSearchHit {
    CoreSearchHit(table: table, id: id, label: "Cached label", excerpt: "Synthetic excerpt")
  }

  private func search(_ read: @escaping (CoreSearchArgs) async throws -> [CoreSearchHit])
    -> QuickFindModel
  {
    QuickFindModel(
      search: read,
      read: { _ in
        Issue.record("Palette activation must use the shared destination resolver")
        return []
      })
  }

  private func metadata(_ views: [CoreSavedViewRecord] = []) -> NativePaletteModel {
    NativePaletteModel(
      catalog: { try catalog() },
      listViews: { _ in
        CoreSavedViewList(views: views, unavailable: nil)
      })
  }

  private func resolved(_ destination: NativeDestination) throws -> NativeResolvedDestination {
    NativeResolvedDestination(
      destination: destination, catalog: try catalog(), view: nil,
      row: destination.rowID.map { WorkspaceRow(record: ["id": .string($0)], label: "Fresh label") }
    )
  }

  @Test func keyboardSelectionUsesExactKindsAndSkipsUnavailableEntries() async throws {
    let first = "\u{00e9}"
    let second = "e\u{0301}"
    let model = QuickFindCoordinator(
      search: search { _ in [hit(first), hit(second)] },
      metadata: metadata([view(first), view("disabled", unavailable: "Core reason"), view(second)]),
      resolve: { destination, _ in try resolved(destination) })
    model.query = "notes"
    await model.loadMetadata()
    await model.reloadSearch()
    #expect(model.entries.count == 6 && Set(model.entries.map(\.id)).count == 6)
    let enabled = [
      NativeDestination(table: "notes"),
      NativeDestination(table: "notes", viewID: first),
      NativeDestination(table: "notes", viewID: second),
      NativeDestination(table: "notes", rowID: first),
      NativeDestination(table: "notes", rowID: second),
    ]
    #expect(model.selection == enabled[0])
    for next in enabled.dropFirst() {
      model.moveSelection(1)
      #expect(model.selection == next)
    }
    model.moveSelection(1)
    #expect(model.selection == enabled[0])
    model.moveSelection(-1)
    #expect(model.selection == enabled.last)
    var opened: [NativeDestination] = []
    await model.activateSelection { opened.append($0.destination) }
    #expect(opened == [enabled.last!])
    let unavailable = try #require(model.entries.first { $0.unavailable != nil })
    #expect(unavailable.unavailable == "Core reason")
    await model.activate(unavailable.id) { opened.append($0.destination) }
    #expect(opened.count == 1)
  }

  @Test func metadataArrivingAfterRecordsRetainsSelectionThroughEachProgressUpdate() async throws {
    var catalogReply: CheckedContinuation<WorkspaceCatalog, Error>?
    var viewReply: CheckedContinuation<CoreSavedViewList, Error>?
    let metadata = NativePaletteModel(
      catalog: {
        try await withCheckedThrowingContinuation { catalogReply = $0 }
      }, listViews: { _ in try await withCheckedThrowingContinuation { viewReply = $0 } })
    let model = QuickFindCoordinator(
      search: search { _ in [hit("chosen")] }, metadata: metadata,
      resolve: { destination, _ in try resolved(destination) })
    model.query = "notes"
    let pending = Task { await model.loadMetadata() }
    try await waitForRequest { catalogReply != nil }
    await model.reloadSearch()
    let record = NativeDestination(table: "notes", rowID: "chosen")
    #expect(model.selection == record)
    catalogReply?.resume(returning: try catalog())
    try await waitForRequest { viewReply != nil }
    // The view calls this when entry availability changes during progressive discovery.
    model.reconcileSelection()
    #expect(model.entries.first?.id == NativeDestination(table: "notes"))
    #expect(model.selection == record)
    viewReply?.resume(returning: CoreSavedViewList(views: [view("saved")], unavailable: nil))
    await pending.value
    #expect(model.selection == record && model.entries.count == 3)
    model.moveSelection(-1)
    #expect(model.selection == NativeDestination(table: "notes", viewID: "saved"))
  }

  @Test func emptyQueriesAndMetadataRetriesRemainSeparateFromRecordPaging() async throws {
    var metadataReads = 0
    var catalogReads = 0
    var requests: [CoreSearchArgs] = []
    let metadata = NativePaletteModel(
      catalog: {
        catalogReads += 1
        return try catalog()
      },
      listViews: { _ in
        metadataReads += 1
        if metadataReads == 1 { throw WorkspaceError(message: "Metadata failure", violations: []) }
        return CoreSavedViewList(views: [view("saved")], unavailable: nil)
      })
    let model = QuickFindCoordinator(
      search: search { args in
        requests.append(args)
        return args.offset == 0
          ? (0..<49).map { hit("row-\($0)") } + [hit("row-0")]
          : [hit("row-0"), hit("next")]
      }, metadata: metadata, resolve: { destination, _ in try resolved(destination) })
    await model.loadMetadata()
    await model.reloadSearch()
    #expect(requests.isEmpty && model.entries.map(\.id) == [NativeDestination(table: "notes")])
    #expect(model.metadata.error == "notes: Metadata failure")
    model.query = "notes"
    await model.reloadSearch()
    model.moveSelection(1)
    let selected = model.selection
    await model.reloadSearch(more: true)
    #expect(requests.map(\.offset) == [0, 50] && model.search.results.count == 50)
    #expect(model.selection == selected)
    #expect(catalogReads == 1 && metadataReads == 1)
    await model.refreshMetadata()
    #expect(model.metadata.error == nil && metadataReads == 2 && catalogReads == 2)
    #expect(requests.count == 2 && model.selection == selected)
    model.query = "  absent  "
    #expect(model.entries.isEmpty && model.selection == nil)
    model.moveSelection(1)
    var opened = false
    await model.activateSelection { _ in opened = true }
    #expect(!opened && metadataReads == 2 && requests.count == 2)
  }

  @Test(arguments: ["close", "workspace", "query", "replacement", "task"], [false, true])
  func obsoleteActivationsCannotCommitOrReplaceTheCurrentError(_ ending: String, fails: Bool)
    async throws
  {
    var held: CheckedContinuation<NativeResolvedDestination, Error>?
    var current = true
    let old = NativeDestination(table: "notes", rowID: "old")
    let latest = NativeDestination(table: "notes", rowID: "latest")
    let model = QuickFindCoordinator(
      search: search { _ in [hit("old"), hit("latest")] }, metadata: metadata(),
      resolve: { destination, _ in
        if destination == old { return try await withCheckedThrowingContinuation { held = $0 } }
        throw WorkspaceError(message: "Current failure", violations: [])
      }, isCurrent: { current })
    model.query = "notes"
    await model.reloadSearch()
    var opened: [NativeDestination] = []
    let pending = Task { await model.activate(old) { opened.append($0.destination) } }
    try await waitForRequest { held != nil }
    switch ending {
    case "close": model.cancel()
    case "workspace": current = false
    case "query": model.query = "different"
    case "task": pending.cancel()
    default: await model.activate(latest) { opened.append($0.destination) }
    }
    if fails {
      held?.resume(throwing: WorkspaceError(message: "Obsolete failure", violations: []))
    } else {
      held?.resume(returning: try resolved(old))
    }
    await pending.value
    #expect(opened.isEmpty)
    #expect(model.error == (ending == "replacement" ? "Current failure" : nil))
    #expect(model.opening == nil)
  }

  @Test func failedHostCommitKeepsThePaletteAndCanRetryWithFreshResolution() async throws {
    var calls = 0
    let destination = NativeDestination(table: "notes")
    let model = QuickFindCoordinator(
      search: search { _ in [] }, metadata: metadata(),
      resolve: { destination, isCurrent in
        #expect(isCurrent())
        calls += 1
        return try resolved(destination)
      })
    await model.loadMetadata()
    await model.activateSelection { _ in
      throw WorkspaceError(message: "Host changed", violations: [])
    }
    #expect(model.error == "Host changed" && model.isCurrent && model.selection == destination)
    var opened: NativeDestination?
    await model.activateSelection { opened = $0.destination }
    #expect(opened == destination && calls == 2 && model.error == nil)
    model.cancel()
    await model.activate(destination) { _ in Issue.record("Closed palette committed") }
    #expect(calls == 2 && !model.isCurrent)
  }

  @Test func searchRetryClearsAnOpeningErrorAndRestartsRecordPaging() async throws {
    var changed = false
    var offsets: [Int] = []
    let model = QuickFindCoordinator(
      search: search { args in
        let start = Int(args.offset ?? 0)
        offsets.append(start)
        return changed ? [hit("fresh")] : (start..<(start + 50)).map { hit(String($0)) }
      }, metadata: metadata(),
      resolve: { _, _ in
        throw WorkspaceError(message: "Record is no longer available", violations: [])
      })
    model.query = "fixture"
    await model.loadMetadata()
    await model.reloadSearch()
    await model.reloadSearch(more: true)
    await model.activate(NativeDestination(table: "notes", rowID: "0")) { _ in
      Issue.record("Unavailable record committed")
    }
    #expect(model.error != nil && model.search.results.count == 100)
    changed = true
    await model.reloadSearch()
    #expect(offsets == [0, 50, 0] && model.search.results.map(\.id) == ["fresh"])
    #expect(model.error == nil && !model.search.canLoadMore)
    #expect(model.metadata.entries.map(\.destination) == [NativeDestination(table: "notes")])
  }

  @Test func anOlderReplyCannotClearANewerOpeningIndicator() async throws {
    var replies: [NativeDestination: CheckedContinuation<NativeResolvedDestination, Error>] = [:]
    let old = NativeDestination(table: "notes", rowID: "old")
    let latest = NativeDestination(table: "notes", rowID: "latest")
    let model = QuickFindCoordinator(
      search: search { _ in [hit("old"), hit("latest")] },
      metadata: metadata(),
      resolve: { destination, _ in
        try await withCheckedThrowingContinuation { replies[destination] = $0 }
      })
    model.query = "notes"
    await model.reloadSearch()
    var opened: [NativeDestination] = []
    let first = Task { await model.activate(old) { opened.append($0.destination) } }
    try await waitForRequest { replies[old] != nil }
    let second = Task { await model.activate(latest) { opened.append($0.destination) } }
    try await waitForRequest { replies[latest] != nil }
    replies[old]?.resume(returning: try resolved(old))
    await first.value
    #expect(model.opening == latest && opened.isEmpty)
    replies[latest]?.resume(returning: try resolved(latest))
    await second.value
    #expect(model.opening == nil && opened == [latest])
  }

  @Test(arguments: [false, true])
  func closingDisposesBothMetadataAndRecordRequests(fails: Bool) async throws {
    var catalogReply: CheckedContinuation<WorkspaceCatalog, Error>?
    var searchReply: CheckedContinuation<[CoreSearchHit], Error>?
    let metadata = NativePaletteModel(
      catalog: {
        try await withCheckedThrowingContinuation { catalogReply = $0 }
      },
      listViews: { _ in
        Issue.record("Closing must stop subsequent metadata reads")
        return CoreSavedViewList(views: [], unavailable: nil)
      })
    let model = QuickFindCoordinator(
      search: search { _ in
        try await withCheckedThrowingContinuation { searchReply = $0 }
      }, metadata: metadata, resolve: { destination, _ in try resolved(destination) })
    model.query = "notes"
    let discovering = Task { await model.loadMetadata() }
    let searching = Task { await model.reloadSearch() }
    try await waitForRequest { catalogReply != nil && searchReply != nil }
    model.cancel()
    if fails {
      catalogReply?.resume(
        throwing: WorkspaceError(message: "Obsolete metadata failure", violations: []))
      searchReply?.resume(
        throwing: WorkspaceError(message: "Obsolete record failure", violations: []))
    } else {
      catalogReply?.resume(returning: try catalog())
      searchReply?.resume(returning: [hit("late")])
    }
    await discovering.value
    await searching.value
    #expect(model.entries.isEmpty && model.selection == nil)
    #expect(model.metadata.entries.isEmpty && model.search.results.isEmpty)
    #expect(model.metadata.error == nil && model.search.error == nil && model.error == nil)
    #expect(!model.metadata.loading && !model.search.loading)
    #expect(!model.metadata.isCurrent && !model.search.isCurrent && !model.isCurrent)
  }

  @Test func workspaceFactoryResolvesFreshRowsAndViewsBeforeInstallingAnything() async throws {
    let workspace = WorkspaceModel()
    await workspace.open(demo: true)
    await workspace.searchIndexSettled()  // the index builds in the background after open
    let client = try #require(workspace.client)
    let note = try await client.write(
      table: "notes",
      patch: [
        "title": .string("Palettefixture record"), "body": .string("Original body"),
      ])
    let saved = try await client.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Palettefixture view",
        definition: CoreSavedViewDefinition(version: 1, columns: ["title"], search: "excluded")))
    let model = try #require(workspace.makeCommandPalette())
    model.query = "Palettefixture"
    await model.loadMetadata()
    await model.reloadSearch()
    let rowDestination = NativeDestination(table: "notes", rowID: note["id"]?.text)
    let viewDestination = NativeDestination(table: "notes", viewID: saved.id)
    #expect(model.entries.contains { $0.id == rowDestination })
    #expect(model.entries.contains { $0.id == viewDestination })
    let updated = try await client.write(
      table: "notes",
      patch: [
        "id": note["id"]!, "title": .string("Fresh renamed row"),
        "body": .string("Fresh complete body"),
      ])
    var opened: [NativeResolvedDestination] = []
    func install(_ resolved: NativeResolvedDestination) throws {
      _ = try workspace.activateDestination(
        resolved, workspace: client, generation: workspace.workspaceGeneration)
      opened.append(resolved)
    }
    await model.activate(rowDestination, commit: install)
    #expect(opened.last?.row?.record == updated)
    #expect(workspace.appliedView == nil && !workspace.trash)
    let renamed = try await client.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Fresh renamed view",
        definition: CoreSavedViewDefinition(version: 1, columns: ["status"], search: "new filter"),
        id: saved.id, expectedUpdatedAt: saved.updatedAt))
    await model.activate(viewDestination, commit: install)
    #expect(workspace.appliedView == renamed && workspace.search == "new filter")
    _ = try await client.deleteView(
      CoreDeleteViewArgs(id: saved.id, expectedUpdatedAt: renamed.updatedAt!))
    let before = workspace.queryKey
    await model.activate(viewDestination, commit: install)
    #expect(opened.count == 2 && workspace.queryKey == before)
    #expect(model.error?.contains("no longer available") == true)
    _ = try await client.write(
      table: "notes", patch: ["id": note["id"]!, "deleted_at": .bool(true)])
    await model.activate(rowDestination, commit: install)
    #expect(opened.count == 3 && opened.last?.isTrashed == true && workspace.trash)
    #expect(opened.last?.row?.record["body"] == .string("Fresh complete body"))
    #expect(model.error == nil)
    workspace.client = nil
    workspace.client = client
    await model.activate(rowDestination) { _ in
      Issue.record("An old workspace generation committed")
    }
    #expect(!model.isCurrent)
    await workspace.close()
    await model.activate(rowDestination) { _ in
      Issue.record("Closed workspace installed a destination")
    }
    #expect(!model.isCurrent)
  }
}
