import Foundation
import Testing

@testable import IrisKit

@MainActor
struct QuickFindTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_QUICK_FIND_SIMULATOR"] != nil))
    func prepareQuickFindUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["IRIS_TEST_QUICK_FIND_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      let workspace = try #require(model.client)
      let existingNotes = try await workspace.rows(table: "notes", search: "amberfalcon")
      for index in 0..<52 {
        let number = String(format: "%02d", index)
        var patch: WorkspaceRecord = [
          "title": .string("Amberfalcon note \(number)"),
          "body": .string("Synthetic body for note \(number)."),
        ]
        if let existing = existingNotes.first(where: { $0.record["title"] == patch["title"] }) {
          patch["id"] = existing.record["id"]
        }
        _ = try await workspace.write(table: "notes", patch: patch)
      }
      let topics = try await workspace.rows(table: "topics", search: "amberfalcon")
      var topic: WorkspaceRecord = ["title": .string("Amberfalcon topic")]
      if let existing = topics.first { topic["id"] = existing.record["id"] }
      _ = try await workspace.write(table: "topics", patch: topic)
      await model.close()
    }
  #endif

  private func hit(_ id: String, table: String = "notes", label: String? = nil) -> CoreSearchHit {
    CoreSearchHit(table: table, id: id, label: label ?? id, excerpt: "Synthetic matching text")
  }

  @Test func paginationUsesRawOffsetsAndTableRowIdentity() async throws {
    var requests: [CoreSearchArgs] = []
    let model = QuickFindModel(
      search: { args in
        requests.append(args)
        if args.offset == 0 { return (0..<49).map { hit(String($0)) } + [hit("0")] }
        return [hit("0"), hit("0", table: "topics"), hit("next")]
      }, read: { _ in [] })
    model.query = "fixture"
    await model.reload()
    #expect(model.results.count == 49)
    #expect(model.canLoadMore)
    await model.reload(more: true)
    #expect(requests.map(\.offset) == [0, 50])
    #expect(requests.allSatisfy { $0.limit == 50 && $0.table == nil && $0.text == "fixture" })
    #expect(model.results.count == 51)
    #expect(model.results.contains { $0.table == "topics" && $0.id == "0" })
    #expect(!model.canLoadMore)
  }

  @Test func blankQueryNeverCallsCoreAndFailuresCanRetryWithoutSkippingAPage() async {
    var calls = 0
    let model = QuickFindModel(
      search: { _ in
        calls += 1
        if calls == 1 { throw WorkspaceError(message: "Synthetic search failure", violations: []) }
        return [hit("found")]
      }, read: { _ in [] })
    model.query = "   "
    await model.reload()
    #expect(calls == 0)
    #expect(model.results.isEmpty && !model.loading)
    model.query = "fixture"
    await model.reload()
    #expect(model.error == "Synthetic search failure")
    #expect(!model.loading)
    await model.reload()
    #expect(model.results.map(\.id) == ["found"])
    #expect(model.error == nil)
  }

  @Test func searchAgainButtonRestartsAfterPagedResultDisappears() async throws {
    var requests: [CoreSearchArgs] = []
    var changed = false
    let model = QuickFindModel(
      search: { args in
        requests.append(args)
        if changed { return args.offset == 0 ? [hit("fresh")] : [] }
        let start = Int(args.offset ?? 0)
        return (start..<(start + 50)).map { hit(String($0)) }
      }, read: { _ in [] })
    let palette = QuickFindCoordinator(
      search: model,
      metadata: NativePaletteModel(
        catalog: {
          try WorkspaceCatalog(CoreCatalog(tables: [], properties: [], rules: []))
        }, listViews: { _ in CoreSavedViewList(views: [], unavailable: nil) }),
      resolve: { _, _ in
        throw WorkspaceError(message: "Record is no longer available", violations: [])
      })
    let view = QuickFindView(model: palette, incomplete: false, onOpen: { _ in })
    palette.query = "fixture"
    await palette.reloadSearch()
    await palette.reloadSearch(more: true)
    #expect(model.results.count == 100)
    let removed = try #require(model.results.first)
    await palette.activate(NativeDestination(table: removed.table, rowID: removed.id)) { _ in
      Issue.record("Missing record committed")
    }
    #expect(palette.error?.contains("no longer available") == true)
    changed = true

    // Invoke the action used by the actual Search again button, not reload directly.
    await view.searchAgain()

    #expect(requests.map(\.offset) == [0, 50, 0])
    #expect(model.results.map(\.id) == ["fresh"])
    #expect(palette.error == nil && model.error == nil)
    #expect(!model.loading && !model.canLoadMore)
  }

  @Test func changingQueryRejectsLatePagesBeforeAnotherRequestStarts() async {
    var response: CheckedContinuation<[CoreSearchHit], Error>?
    let model = QuickFindModel(
      search: { args in
        if args.offset == 0 { return (0..<50).map { hit(String($0)) } }
        return try await withCheckedThrowingContinuation { response = $0 }
      }, read: { _ in [] })
    model.query = "old"
    await model.reload()
    let more = Task { await model.reload(more: true) }
    while response == nil { await Task.yield() }
    model.query = "new"
    #expect(model.results.isEmpty && !model.loading)
    response?.resume(returning: [hit("late")])
    await more.value
    #expect(model.results.isEmpty && !model.canLoadMore)
  }

  @Test func oldQueryErrorCannotReplaceNewResults() async {
    var response: CheckedContinuation<[CoreSearchHit], Error>?
    let model = QuickFindModel(
      search: { args in
        if args.text == "old" { return try await withCheckedThrowingContinuation { response = $0 } }
        return [hit("new")]
      }, read: { _ in [] })
    model.query = "old"
    let old = Task { await model.reload() }
    while response == nil { await Task.yield() }
    model.query = "new"
    await model.reload()
    response?.resume(throwing: WorkspaceError(message: "Obsolete failure", violations: []))
    await old.value
    #expect(model.results.map(\.id) == ["new"])
    #expect(model.error == nil && !model.loading)
  }

  @Test(arguments: ["cancel", "workspace", "query"])
  func lateOpeningCannotNavigateAfterItsContextChanges(reason: String) async {
    var current = true
    var response: CheckedContinuation<[WorkspaceRow], Error>?
    let chosen = hit("chosen")
    let model = QuickFindModel(
      search: { _ in [chosen] },
      read: { view in
        #expect(view.table == "notes" && view.limit == 1)
        #expect(view.columns == nil && view.search == nil)
        #expect(view.filters == [CoreFilter(column: "id", op: .eq, value: .string("chosen"))])
        return try await withCheckedThrowingContinuation { response = $0 }
      }, isCurrent: { current })
    model.query = "fixture"
    await model.reload()
    let opening = Task { await model.open(chosen) }
    while response == nil { await Task.yield() }
    switch reason {
    case "cancel": model.cancel()
    case "workspace": current = false
    default: model.query = "new"
    }
    response?.resume(returning: [WorkspaceRow(record: ["id": .string("chosen")], label: "Fresh")])
    #expect(await opening.value == nil)
  }

  @Test func newerOpenWinsAndMissingRowsStayInSearchWithAnError() async {
    var response: CheckedContinuation<[WorkspaceRow], Error>?
    let a = hit("a")
    let b = hit("b")
    let model = QuickFindModel(
      search: { _ in [a, b] },
      read: { view in
        if view.filters?.first?.value == .string("a") {
          return try await withCheckedThrowingContinuation { response = $0 }
        }
        return []
      })
    model.query = "fixture"
    await model.reload()
    let old = Task { await model.open(a) }
    while response == nil { await Task.yield() }
    #expect(await model.open(b) == nil)
    #expect(model.error?.contains("no longer available") == true)
    response?.resume(returning: [WorkspaceRow(record: ["id": .string("a")], label: "Late")])
    #expect(await old.value == nil)
    #expect(model.opening == nil)
    #expect(model.error?.contains("no longer available") == true)
  }

  @Test func cancellationAndWorkspaceChangeRejectOutstandingSearches() async {
    for cancel in [true, false] {
      var current = true
      var response: CheckedContinuation<[CoreSearchHit], Error>?
      let model = QuickFindModel(
        search: { _ in
          try await withCheckedThrowingContinuation { response = $0 }
        }, read: { _ in [] }, isCurrent: { current })
      model.query = "fixture"
      let request = Task { await model.reload() }
      while response == nil { await Task.yield() }
      if cancel { model.cancel() } else { current = false }
      response?.resume(returning: [hit("late")])
      await request.value
      #expect(model.results.isEmpty)
      #expect(!model.isCurrent)
    }
  }

  @Test func realCoreSearchSpansTablesAndOpeningReadsTheFreshFullRow() async throws {
    let workspace = WorkspaceModel()
    await workspace.open(demo: true)
    await workspace.searchIndexSettled()  // the index builds in the background after open
    let client = try #require(workspace.client)
    let note = try await client.write(
      table: "notes",
      patch: [
        "title": .string("Orchid note"), "body": .string("Synthetic orchid body"),
      ])
    _ = try await client.write(table: "topics", patch: ["title": .string("Orchid topic")])
    let find = try #require(workspace.makeQuickFind())
    find.query = "orchid"
    await find.reload()
    #expect(Set(find.results.map(\.table)) == ["notes", "topics"])
    let result = try #require(find.results.first { $0.table == "notes" })
    #expect(result.excerpt.contains("orchid"))
    let changed = try await client.write(
      table: "notes",
      patch: [
        "id": note["id"]!, "title": .string("Renamed note"),
        "body": .string("Latest complete source"),
      ], expectedUpdatedAt: note["updated_at"]?.text)
    let row = try #require(await find.open(result))
    #expect(row.record["body"] == .string("Latest complete source"))
    #expect(row.record["updated_at"] == changed["updated_at"])
    #expect(row.label == "Renamed note")
    let epoch = workspace.workspaceGeneration
    workspace.trash = true
    let context = try workspace.activateSearchTable("topics", workspace: client, generation: epoch)
    #expect(context.table == "topics" && !workspace.trash && !workspace.canWrite)
    await workspace.reload()
    #expect(workspace.canWrite)
    _ = try workspace.activateSearchTable("history", workspace: client, generation: epoch)
    #expect(!workspace.canWrite)
    await workspace.open(demo: true)
    #expect(!find.isCurrent)
    #expect(throws: WorkspaceError.self) {
      try workspace.activateSearchTable("notes", workspace: client, generation: epoch)
    }
    await workspace.close()
  }
}
