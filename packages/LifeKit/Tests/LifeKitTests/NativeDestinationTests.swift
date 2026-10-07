import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct NativeDestinationTests {
  private func catalog() throws -> WorkspaceCatalog {
    try WorkspaceCatalog(CoreCatalog(tables: [["id": .string("notes")]], properties: [], rules: []))
  }

  private func savedView() -> CoreSavedViewRecord {
    CoreSavedViewRecord(id: "view", name: "Current view", tbl: "notes", updatedAt: "revision",
      deletedAt: nil, definition: CoreSavedViewDefinition(version: 1),
      view: CoreView(table: "notes"), unavailable: nil)
  }

  @Test func identityAndPersistenceKeepExactOpaqueIDsWithoutLabels() throws {
    let first = NativeDestination(table: "notes", viewID: "\u{00E9}", rowID: "e\u{0301}")
    let otherRow = NativeDestination(table: "notes", viewID: "\u{00E9}", rowID: "\u{00E9}")
    let otherView = NativeDestination(table: "notes", viewID: "e\u{0301}", rowID: "e\u{0301}")
    #expect(Set([first, otherRow, otherView]).count == 3)
    #expect(first.identity == [Data("notes".utf8), Data([0xc3, 0xa9]), Data([0x65, 0xcc, 0x81])])
    let data = try JSONEncoder().encode(first)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(Set(json.keys) == ["table", "view", "row"])
    #expect(json["row"].map { Data($0.utf8) } == Data([0x65, 0xcc, 0x81]))
    let restored = try JSONDecoder().decode(NativeDestination.self, from: data)
    #expect(restored == first && restored != otherRow && restored != otherView)
    let table = NativeDestination(table: "notes")
    #expect(try JSONDecoder().decode(NativeDestination.self, from: JSONEncoder().encode(table)) == table)
    #expect(table != NativeDestination(table: "notes", rowID: ""))
  }

  @Test func realCoreResolutionUsesFreshViewsAndFullRowsWithoutApplyingTheirQuery() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let note = try await workspace.write(table: "notes", patch: [
      "title": .string("Original title"), "body": .string("Hidden body"), "status": .string("Draft")])
    let view = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "Original view",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"], search: "not-this-record")))
    let resolver = NativeDestinationResolver(workspace: workspace)
    let table = try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true })
    #expect(table.label == "notes" && table.view == nil && table.row == nil && !table.isTrashed)
    let renamed = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "Renamed view",
      definition: CoreSavedViewDefinition(version: 1, columns: ["status"], search: "still-excluded"),
      id: view.id, expectedUpdatedAt: view.updatedAt))
    let updated = try await workspace.write(table: "notes", patch: [
      "id": note["id"]!, "title": .string("Fresh title"), "body": .string("Fresh complete body")])
    let before = try await workspace.status()
    let destination = NativeDestination(table: "notes", viewID: view.id, rowID: note["id"]?.text)
    let resolved = try await resolver.resolve(destination, isCurrent: { true })
    #expect(resolved.destination == destination)
    #expect(resolved.view == renamed)
    #expect(resolved.row?.record == updated)
    #expect(resolved.label == "Fresh title" && !resolved.isTrashed)
    #expect(resolved.catalog.tables.contains { $0["id"] == .string("notes") })
    let viewOnly = try await resolver.resolve(
      NativeDestination(table: "notes", viewID: view.id), isCurrent: { true })
    #expect(viewOnly.label == "Renamed view" && viewOnly.row == nil)
    #expect(try await workspace.status() == before)
    try await workspace.close()
  }

  @Test(arguments: [false, true], [false, true])
  func realCoreResolutionFindsBothLiveAndTrashedRows(trashed: Bool, viewTrash: Bool) async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let note = try await workspace.write(table: "notes", patch: [
      "title": .string("Explicit destination"), "body": .string("Full hidden body")])
    if trashed {
      _ = try await workspace.write(table: "notes", patch: ["id": note["id"]!, "deleted_at": .bool(true)])
    }
    let view = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "Chosen view",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"], trash: viewTrash)))
    let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
      NativeDestination(table: "notes", viewID: view.id, rowID: note["id"]?.text), isCurrent: { true })
    #expect(resolved.label == "Explicit destination")
    #expect(resolved.row?.record["body"] == .string("Full hidden body"))
    #expect(resolved.isTrashed == trashed)
    #expect(resolved.view?.definition?.trash == viewTrash)
    try await workspace.close()
  }

  @Test func realCoreResolutionSeparatesCanonicalEquivalentViewAndRowIDs() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      ["\u00e9", "e\u0301"].forEach((id, i) => {
        LifeSql.run("INSERT INTO notes(id,title,body) VALUES (?,?,?)", [id, "Row " + i, "Body " + i]);
        LifeSql.run("INSERT INTO views(id,name,tbl,definition) VALUES (?,?,'notes',?)", [id, "View " + i, '{"version":1}']);
      });
      """#)
    #expect(runtime.context.exception == nil)
    let resolver = NativeDestinationResolver(workspace: workspace)
    let first = try await resolver.resolve(
      NativeDestination(table: "notes", viewID: "\u{00E9}", rowID: "e\u{0301}"), isCurrent: { true })
    let second = try await resolver.resolve(
      NativeDestination(table: "notes", viewID: "e\u{0301}", rowID: "\u{00E9}"), isCurrent: { true })
    #expect(first.view?.name == "View 0" && first.label == "Row 1")
    #expect(second.view?.name == "View 1" && second.label == "Row 0")
    #expect(first.row.map { Data($0.id.utf8) } == Data([0x65, 0xcc, 0x81]))
    #expect(second.row.map { Data($0.id.utf8) } == Data([0xc3, 0xa9]))
    try await workspace.close()
  }

  @Test(arguments: ["table", "view", "row", "deletedView", "unsupportedView"])
  func realCoreRejectsUnavailableDestinations(_ missing: String) async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let view = try await workspace.saveView(CoreSaveViewArgs(table: "notes", name: "Saved view",
      definition: CoreSavedViewDefinition(version: 1)))
    if missing == "deletedView" {
      _ = try await workspace.deleteView(CoreDeleteViewArgs(id: view.id, expectedUpdatedAt: view.updatedAt!))
    } else if missing == "unsupportedView" {
      runtime.context.evaluateScript(#"LifeSql.run("UPDATE views SET definition='{\"version\":999}'")"#)
      #expect(runtime.context.exception == nil)
    }
    let destination = NativeDestination(table: missing == "table" ? "missing" : "notes",
      viewID: missing == "row" || missing == "table" ? nil : missing == "view" ? "missing" : view.id,
      rowID: missing == "row" ? "missing" : nil)
    await #expect(throws: WorkspaceError.self) {
      try await NativeDestinationResolver(workspace: workspace).resolve(destination, isCurrent: { true })
    }
    try await workspace.close()
  }

  @Test(arguments: [false, true])
  func realCoreCollatedRowAliasesDoNotResolveAnotherOpaqueID(_ trashed: Bool) async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      LifeSql.run(`CREATE TABLE collated (id TEXT PRIMARY KEY COLLATE NOCASE,
        created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, title TEXT)`);
      LifeSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('collated','table','title')");
      LifeSql.run("INSERT INTO collated(id,title) VALUES ('A','Exact stored identity')");
      """#)
    if trashed { runtime.context.evaluateScript(#"LifeSql.run("UPDATE collated SET deleted_at='deleted'")"#) }
    #expect(runtime.context.exception == nil)
    let aliased = try await workspace.rows(view: CoreView(table: "collated",
      filters: [CoreFilter(column: "id", op: .eq, value: .string("a"))], limit: 1, trash: trashed))
    #expect(aliased.count == 1 && aliased.first.map { Data($0.id.utf8) } == Data("A".utf8))
    let resolver = NativeDestinationResolver(workspace: workspace)
    let exact = try await resolver.resolve(NativeDestination(table: "collated", rowID: "A"), isCurrent: { true })
    #expect(exact.label == "Exact stored identity" && exact.isTrashed == trashed)
    await #expect(throws: WorkspaceError.self) {
      try await resolver.resolve(NativeDestination(table: "collated", rowID: "a"), isCurrent: { true })
    }
    try await workspace.close()
  }

  @Test(arguments: ["otherTable", "tombstone", "unavailable", "definition", "query"])
  func invalidViewMetadataNeverReadsARecord(_ invalid: String) async throws {
    var view = savedView()
    switch invalid {
    case "otherTable": view.tbl = "topics"
    case "tombstone": view.deletedAt = "deleted"
    case "unavailable": view.unavailable = "Core availability reason"
    case "definition": view.definition = nil
    default: view.view = nil
    }
    var rowReads = 0
    let resolver = NativeDestinationResolver(catalog: catalog, listViews: { _ in
      CoreSavedViewList(views: [view], unavailable: nil)
    }, rows: { _ in rowReads += 1; return [] })
    do {
      _ = try await resolver.resolve(
        NativeDestination(table: "notes", viewID: "view", rowID: "row"), isCurrent: { true })
      Issue.record("An unavailable view opened a record")
    } catch let error as WorkspaceError {
      if invalid == "unavailable" { #expect(error.message == "Core availability reason") }
    }
    #expect(rowReads == 0)
  }

  @Test(arguments: ["catalog", "views", "active", "trash"], [false, true])
  func obsoleteSuccessesAndErrorsStopAtEveryReadBoundary(_ boundary: String, fails: Bool) async throws {
    for cancelTask in [false, true] {
      var continuation: CheckedContinuation<Void, Error>?
      var current = true
      var reads: [String] = []
      func checkpoint(_ stage: String) async throws {
        reads.append(stage)
        if stage == boundary { try await withCheckedThrowingContinuation { continuation = $0 } }
      }
      let resolver = NativeDestinationResolver(catalog: {
        try await checkpoint("catalog")
        return try catalog()
      }, listViews: { _ in
        try await checkpoint("views")
        return CoreSavedViewList(views: [savedView()], unavailable: nil)
      }, rows: { view in
        try await checkpoint(view.trash == true ? "trash" : "active")
        if boundary == "trash" && view.trash != true { return [] }
        return [WorkspaceRow(record: ["id": .string("row")], label: "Resolved")]
      })
      let pending = Task {
        try await resolver.resolve(
          NativeDestination(table: "notes", viewID: "view", rowID: "row"), isCurrent: { current })
      }
      while continuation == nil { await Task.yield() }
      if cancelTask { pending.cancel() } else { current = false }
      if fails { continuation?.resume(throwing: WorkspaceError(message: "Obsolete error", violations: [])) }
      else { continuation?.resume() }
      await #expect(throws: CancellationError.self) { try await pending.value }
      #expect(reads.last == boundary)
    }
  }

  @Test func obsoleteCallsNeverReadAndIndependentCallersDoNotSupersedeEachOther() async throws {
    var first: CheckedContinuation<WorkspaceCatalog, Error>?
    var calls = 0
    let resolver = NativeDestinationResolver(catalog: {
      calls += 1
      if calls == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
      return try catalog()
    }, listViews: { _ in
      Issue.record("Table destinations must not list views")
      return CoreSavedViewList(views: [], unavailable: nil)
    }, rows: { _ in
      Issue.record("Table destinations must not read rows")
      return []
    })
    await #expect(throws: CancellationError.self) {
      try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { false })
    }
    #expect(calls == 0)
    let pending = Task { try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true }) }
    while first == nil { await Task.yield() }
    let second = try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true })
    first?.resume(returning: try catalog())
    #expect(try await pending.value.label == "notes")
    #expect(second.label == "notes" && calls == 2)
  }
}

extension NativeDestinationTests {
  @Test func preferredViewUsesIdentityAndExplicitDestinationsWin() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let note = try #require(try await workspace.rows(view: CoreView(table: "notes")).first)
    let saved = try await workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Preferred",
        definition: CoreSavedViewDefinition(version: 1, search: "not-the-record")))
    _ = try await workspace.setViewDefault(
      CoreSetViewDefaultArgs(table: "notes", viewId: saved.id, expectedUpdatedAt: nil))
    let resolver = NativeDestinationResolver(workspace: workspace)
    let plain = try await resolver.resolve(NativeDestination(table: "notes"), isCurrent: { true })
    #expect(plain.view?.id == saved.id)
    #expect(plain.defaultNotice == nil)
    let explicit = try await resolver.resolve(
      NativeDestination(table: "notes", rowID: note.id), isCurrent: { true })
    #expect(explicit.view == nil)
    #expect(explicit.row?.id == note.id)
    _ = try await workspace.deleteView(
      CoreDeleteViewArgs(id: saved.id, expectedUpdatedAt: saved.updatedAt!))
    let fallback = try await resolver.resolve(
      NativeDestination(table: "notes"), isCurrent: { true })
    #expect(fallback.view == nil)
    #expect(fallback.defaultNotice?.isEmpty == false)
    #expect(try await workspace.getViewDefault(table: "notes").viewId == saved.id)
    try await workspace.close()
  }
}
