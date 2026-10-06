import Foundation
import Testing

@testable import LifeKit

@MainActor
struct WorkspaceExportTests {
  private let capturedAt = Date(timeIntervalSince1970: 1_767_225_600)

  @Test func closingAnUnchangedRecordDoesNotStrandExport() async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    let workspace = try #require(model.client)
    let row = try #require(model.rows.first)
    let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
      NativeDestination(table: "notes", rowID: row.id), isCurrent: { true })
    _ = try model.refreshedRecordContext(
      resolved, workspace: workspace, generation: model.workspaceGeneration)
    #expect(model.canExportLoadedRows)
    #expect(try model.captureLoadedRowsForExport(at: capturedAt).rows == model.rows.map(\.record))
    await model.close()
  }

  @Test(arguments: [false, true])
  func loadMoreAfterQueryChangeRestartsWithoutKeepingOldQueryRows(whileReloading: Bool) async throws
  {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    model.search = "no-such-synthetic-row"
    var old: Task<Void, Never>?
    if whileReloading {
      fixture.holdNext("rows")
      old = Task { await model.reload() }
      try await fixture.waitUntilHeld()
    }
    defer { fixture.release() }
    var started = false
    let more = Task {
      started = true
      await model.reload(more: true)
    }
    while !started { await Task.yield() }
    fixture.release()
    await old?.value
    await more.value
    #expect(model.rows.isEmpty)
    #expect(model.canExportLoadedRows)
    #expect(try model.captureLoadedRowsForExport(at: capturedAt).rows.isEmpty)
    await model.close()
  }

  @Test func catalogIdentityPreservesExactUnicodeMetadata() async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    model.catalog = try changingLabel(try #require(model.catalog), to: "e\u{301}")
    await model.reload()
    #expect(model.canExportLoadedRows)
    model.catalog = try changingLabel(try #require(model.catalog), to: "\u{e9}")
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    await model.reload(more: true)
    #expect(model.canExportLoadedRows)
    #expect(model.rows.count == 1)
    await model.close()
  }

  private func changingLabel(_ catalog: WorkspaceCatalog, to label: String) throws
    -> WorkspaceCatalog
  {
    var tables = catalog.tables
    tables[0]["label"] = .string(label)
    let value = CoreJSONValue.object([
      "tables": .array(tables.map(CoreJSONValue.object)),
      "properties": .array(catalog.properties.map(CoreJSONValue.object)),
      "rules": .array(catalog.rules.map(CoreJSONValue.object)),
    ])
    return try WorkspaceCatalog(
      JSONDecoder().decode(CoreCatalog.self, from: JSONEncoder().encode(value)))
  }

  @Test(arguments: ["cancel", "failure"])
  func nextPageRetryRetainsSuccessfulPrefix(outcome: String) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    try fixture.addPaginationRows()
    await model.reload()
    #expect(model.rows.count == 100)
    await model.reload(more: true)
    #expect(model.rows.count == 200)
    let prefix = model.rows.map(\.byteExactID)
    fixture.holdNext("rows")
    let next = Task { await model.reload(more: true) }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    if outcome == "cancel" {
      next.cancel()
    } else {
      fixture.runtime.context.evaluateScript(
        "LifeSql.run('ALTER TABLE notes RENAME TO held_notes')")
      try #require(fixture.runtime.context.exception == nil)
    }
    fixture.release()
    await next.value
    #expect(model.rows.map(\.byteExactID) == prefix)
    #expect(!model.canExportLoadedRows)
    if outcome == "failure" {
      fixture.runtime.context.evaluateScript(
        "LifeSql.run('ALTER TABLE held_notes RENAME TO notes')")
      try #require(fixture.runtime.context.exception == nil)
    }
    await model.reload(more: true)
    #expect(model.rows.count == 225)
    #expect(Array(model.rows.prefix(200).map(\.byteExactID)) == prefix)
    #expect(Set(model.rows.map(\.byteExactID)).count == 225)
    #expect(try model.captureLoadedRowsForExport(at: capturedAt).rows.count == 225)
    await model.close()
  }

  @Test(arguments: [false, true])
  func fullRefreshInvalidatesPrefixEvenWhenItDoesNotFinish(afterWrite: Bool) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    try fixture.addPaginationRows()
    await model.reload()
    await model.reload(more: true)
    #expect(model.rows.count == 200)
    let original = try #require(model.rows.first?.record)
    fixture.holdNext("rows")
    let refresh = Task {
      if afterWrite {
        _ = try await model.save(
          ["id": original["id"]!, "body": .string("Committed new value")],
          original: original, context: model.editingContext)
      } else {
        await model.reload()
      }
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    if afterWrite {
      fixture.runtime.context.evaluateScript(
        "LifeSql.run('ALTER TABLE notes RENAME TO held_notes')")
      try #require(fixture.runtime.context.exception == nil)
    } else {
      refresh.cancel()
    }
    fixture.release()
    try await refresh.value
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    if afterWrite {
      fixture.runtime.context.evaluateScript(
        "LifeSql.run('ALTER TABLE held_notes RENAME TO notes')")
      try #require(fixture.runtime.context.exception == nil)
    }
    await model.reload(more: true)
    #expect(model.rows.count == 100)
    #expect(model.canExportLoadedRows)
    if afterWrite {
      #expect(model.rows.first?.record["body"] == .string("Committed new value"))
    }
    await model.close()
  }

  @Test func absentOrClosedWorkspaceHasNoLoadedCapture() async throws {
    let model = WorkspaceModel()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    await model.open(demo: true)
    #expect(model.canExportLoadedRows)
    await model.close()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
  }

  @Test func captureCopiesCommittedRowsAndMetadataWithoutAnyCoreRequest() async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    let original = try #require(model.rows.first?.record)
    let raw = "# Stored\r\n\n_source_  \n雪"
    _ = try await model.save(
      ["id": original["id"]!, "body": .string(raw)], original: original,
      context: model.editingContext)
    model.syncStatus = .init(
      lastSuccessfulSync: nil, pendingUiEdits: 2, rejected: 1, skippedTables: ["opaque_skipped"])
    let requests = fixture.requests
    let snapshot = try model.captureLoadedRowsForExport(at: capturedAt)
    #expect(fixture.requests == requests)
    #expect(snapshot.rows == model.rows.map(\.record))
    #expect(snapshot.properties == model.properties)
    #expect(snapshot.rows.first?["body"] == .string(raw))
    #expect(snapshot.scope == .loaded)
    #expect(snapshot.completeness.rows == .unknown)
    #expect(snapshot.completeness.columns == .full)
    #expect(snapshot.acquisition.source == .localReplica)
    #expect(snapshot.acquisition.capturedAt == "2026-01-01T00:00:00.000Z")
    #expect(snapshot.acquisition.lastSync == nil)
    #expect(snapshot.acquisition.pendingUiEdits == 2)
    #expect(snapshot.acquisition.rejectedEdits == 1)
    #expect(snapshot.acquisition.skippedTables == ["opaque_skipped"])
    #expect(snapshot.acquisition.freshness == .unknown)

    // An unsaved editor draft is never the host's persisted row source.
    let draft = RecordDraft(properties: model.properties, original: model.rows.first?.record)
    var edited = draft
    edited.setValue("Unsaved draft", for: "body")
    #expect(try model.captureLoadedRowsForExport(at: capturedAt).rows == snapshot.rows)
    model.table = "topics"
    await model.reload()
    #expect(snapshot.table == "notes")
    #expect(snapshot.rows.first?["body"] == .string(raw))
    await model.close()
  }

  @Test(arguments: ["query", "catalog", "table", "workspace"])
  func contextChangeInvalidatesCaptureBeforeTheNextReload(kind: String) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    switch kind {
    case "query": model.search = "new query"
    case "catalog":
      model.catalog = try changingLabel(try #require(model.catalog), to: "Changed synthetic label")
    case "table": model.table = "topics"
    default:
      let prior = model.client
      model.client = nil
      model.client = prior
      model.table = "notes"
    }
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    await model.reload()
    #expect(model.canExportLoadedRows)
    await model.close()
  }

  @Test func queryIdentityUsesExactUTF8AndAnEmptySuccessfulPageIsExportable() async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    model.search = "e\u{301}"
    await model.reload()
    #expect(model.canExportLoadedRows)
    #expect(try model.captureLoadedRowsForExport(at: capturedAt).rows.isEmpty)
    model.search = "\u{e9}"
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    await model.close()
  }

  @Test(arguments: ["success", "cancel", "catalog", "query", "failure"])
  func heldRefreshNeverExportsOldOrMixedContext(outcome: String) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    let snapshot = try model.captureLoadedRowsForExport(at: capturedAt)
    fixture.holdNext("rows")
    let refresh = Task { await model.reload() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    switch outcome {
    case "cancel": refresh.cancel()
    case "catalog":
      model.catalog = try changingLabel(try #require(model.catalog), to: "Changed synthetic label")
    case "query": model.search = "superseded"
    case "failure":
      fixture.runtime.context.evaluateScript("LifeSql.run('DROP TABLE notes')")
      try #require(fixture.runtime.context.exception == nil)
    default: break
    }
    fixture.release()
    await refresh.value
    #expect(model.canExportLoadedRows == (outcome == "success"))
    if outcome != "success" {
      #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    }
    #expect(snapshot.table == "notes" && !snapshot.rows.isEmpty)
    if outcome == "cancel" {
      #expect(model.rows.map(\.record) == snapshot.rows)
      await model.reload()
      #expect(model.canExportLoadedRows)
    }
    await model.close()
  }

  @Test(arguments: [false, true])
  func pendingWriteBlocksCaptureUntilCommittedRefresh(cancel: Bool) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    let original = try #require(model.rows.first?.record)
    let snapshot = try model.captureLoadedRowsForExport(at: capturedAt)
    fixture.holdNext("write")
    let write = Task {
      try await model.save(
        ["id": original["id"]!, "body": .string("Committed after capture")],
        original: original, context: model.editingContext)
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    if cancel { write.cancel() }
    fixture.release()
    _ = try await write.value
    #expect(model.canExportLoadedRows)
    #expect(
      try model.captureLoadedRowsForExport(at: capturedAt).rows.first?["body"]
        == .string("Committed after capture"))
    #expect(snapshot.rows.first?["body"] == original["body"])
    await model.close()
  }

  @Test func pendingUndoBlocksCaptureUntilItsOwnedRefresh() async throws {
    let fixture = try await ExportWorkspaceFixture()
    let model = fixture.model
    let original = try #require(model.rows.first?.record)
    _ = try await model.save(
      ["id": original["id"]!, "body": .string("To undo")], original: original,
      context: model.editingContext)
    let action = try #require(model.undoAction)
    fixture.holdNext("undo")
    let undo = Task { try await model.undo(action, context: model.editingContext) }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    fixture.release()
    _ = try await undo.value
    #expect(model.canExportLoadedRows)
    await model.close()
  }
}

@MainActor private final class ExportWorkspaceFixture {
  let runtime: LifeCoreRuntime
  let model: WorkspaceModel

  init() async throws {
    runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    model = WorkspaceModel()
    model.client = workspace
    model.catalog = try await workspace.catalog()
    model.table = "notes"
    await model.reload()
    try #require(!model.rows.isEmpty)
    runtime.context.evaluateScript(
      #"""
      globalThis.exportRequests = [];
      globalThis.exportHeldMethod = null;
      globalThis.releaseExportRequest = null;
      const exportRequest = LifeNative.request;
      LifeNative.request = function(id, method, args) {
        exportRequests.push(method);
        if (method !== exportHeldMethod) return exportRequest(id, method, args);
        exportHeldMethod = null;
        globalThis.releaseExportRequest = () => {
          releaseExportRequest = null;
          exportRequest(id, method, args);
        };
      };
      """#)
    try #require(runtime.context.exception == nil)
  }

  func addPaginationRows() throws {
    runtime.context.evaluateScript(
      "for (let i = 0; i < 224; i++) LifeSql.run('INSERT INTO notes (id, title) VALUES (?, ?)', ['page-' + i, 'Synthetic page ' + i])"
    )
    try #require(runtime.context.exception == nil)
  }

  var requests: [String] {
    runtime.context.evaluateScript("exportRequests")?.toArray() as? [String] ?? []
  }
  func holdNext(_ method: String) {
    runtime.context.setObject(method, forKeyedSubscript: "exportHeldMethod" as NSString)
  }
  func release() { runtime.context.evaluateScript("releaseExportRequest?.()") }
  func waitUntilHeld() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while runtime.context.evaluateScript("releaseExportRequest !== null")?.toBool() != true,
      ContinuousClock.now < deadline
    { await Task.yield() }
    try #require(runtime.context.evaluateScript("releaseExportRequest !== null")?.toBool() == true)
  }
}
