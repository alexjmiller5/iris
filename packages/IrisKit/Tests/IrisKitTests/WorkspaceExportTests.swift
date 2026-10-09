import Foundation
import Testing

@testable import IrisKit

@MainActor
struct WorkspaceExportTests {
  private let capturedAt = Date(timeIntervalSince1970: 1_767_225_600)

  @Test(arguments: [false, true])
  func fixtureAdmissionSignalWorksBeforeAndAfterWaitStarts(admittedFirst: Bool) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let observed = ExportAdmissionObserver()
    fixture.holdNext("rows", onHeld: { observed.signal() })
    let refresh = Task { await fixture.model.reload() }
    defer {
      refresh.cancel()
      fixture.release()
    }
    if admittedFirst {
      try #require(await observed.wait(), "Actual JSC admission must precede the waiter")
    } else {
      // No suspension yet: the child reload cannot have entered JSC on MainActor.
      #expect(
        fixture.runtime.context.evaluateScript("releaseExportRequest === null")?.toBool() == true)
    }
    try await fixture.waitUntilHeld()
    #expect(!fixture.model.canExportLoadedRows)
    fixture.release()
    await refresh.value
    #expect(fixture.model.canExportLoadedRows)
    #expect(try fixture.model.captureLoadedRowsForExport(at: capturedAt).rows.count == 1)
    await fixture.model.close()
  }

  @Test(arguments: [false, true])
  func missingAdmissionSignalOrCancelledWaitReleasesWithoutClosingQueue(cancel: Bool) async throws {
    let fixture = try await ExportWorkspaceFixture()
    let observed = ExportAdmissionObserver()
    fixture.holdNext("rows")
    // Suppress only the notification, keeping the real JSC release closure intact.
    let didHold: @convention(block) () -> Void = { observed.signal() }
    fixture.runtime.context.setObject(didHold, forKeyedSubscript: "exportRequestHeld" as NSString)
    let refresh = Task { await fixture.model.reload() }
    defer {
      refresh.cancel()
      fixture.release()
    }
    try #require(await observed.wait(), "Missing-signal fixture must actually hold the request")
    var threw = false
    await withKnownIssue("Missing admission notification must fail the throwing requirement") {
      let waiter = Task { try await fixture.waitUntilHeld(watchdogAfter: .milliseconds(20)) }
      if cancel { waiter.cancel() }
      do { try await waiter.value } catch { threw = true }
    }
    #expect(threw)
    #expect(
      fixture.model.client != nil, "Failure cleanup must not await or close the suspect queue")
    #expect(
      fixture.runtime.context.evaluateScript(
        "exportHeldMethod === null && releaseExportRequest === null")?.toBool() == true)
    await refresh.value
    await fixture.model.reload()
    #expect(fixture.model.canExportLoadedRows)
    #expect(try fixture.model.captureLoadedRowsForExport(at: capturedAt).rows.count == 1)
    await fixture.model.close()
  }

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
    defer {
      old?.cancel()
      fixture.release()
    }
    if whileReloading {
      fixture.holdNext("rows")
      old = Task { await model.reload() }
      try await fixture.waitUntilHeld()
    }
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
    defer {
      next.cancel()
      fixture.release()
    }
    try await fixture.waitUntilHeld()
    if outcome == "cancel" {
      next.cancel()
    } else {
      fixture.runtime.context.evaluateScript(
        "IrisSql.run('ALTER TABLE notes RENAME TO held_notes')")
      try #require(fixture.runtime.context.exception == nil)
    }
    fixture.release()
    await next.value
    #expect(model.rows.map(\.byteExactID) == prefix)
    #expect(!model.canExportLoadedRows)
    if outcome == "failure" {
      fixture.runtime.context.evaluateScript(
        "IrisSql.run('ALTER TABLE held_notes RENAME TO notes')")
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
    defer {
      refresh.cancel()
      fixture.release()
    }
    try await fixture.waitUntilHeld()
    if afterWrite {
      fixture.runtime.context.evaluateScript(
        "IrisSql.run('ALTER TABLE notes RENAME TO held_notes')")
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
        "IrisSql.run('ALTER TABLE held_notes RENAME TO notes')")
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
    defer {
      refresh.cancel()
      fixture.release()
    }
    try await fixture.waitUntilHeld()
    #expect(!model.canExportLoadedRows)
    #expect(throws: WorkspaceError.self) { try model.captureLoadedRowsForExport(at: capturedAt) }
    switch outcome {
    case "cancel": refresh.cancel()
    case "catalog":
      model.catalog = try changingLabel(try #require(model.catalog), to: "Changed synthetic label")
    case "query": model.search = "superseded"
    case "failure":
      fixture.runtime.context.evaluateScript("IrisSql.run('DROP TABLE notes')")
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
    defer {
      write.cancel()
      fixture.release()
    }
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
    defer {
      undo.cancel()
      fixture.release()
    }
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
  let runtime: IrisCoreRuntime
  let model: WorkspaceModel
  private var heldStart: AsyncStream<Void>?
  private var heldContinuation: AsyncStream<Void>.Continuation?
  private var heldMethod: String?

  init() async throws {
    runtime = try IrisCoreRuntime()
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
      const exportRequest = IrisNative.request;
      IrisNative.request = function(id, method, args) {
        exportRequests.push(method);
        if (method !== exportHeldMethod) return exportRequest(id, method, args);
        exportHeldMethod = null;
        globalThis.releaseExportRequest = () => {
          releaseExportRequest = null;
          exportRequest(id, method, args);
        };
        exportRequestHeld();
      };
      """#)
    try #require(runtime.context.exception == nil)
  }

  func addPaginationRows() throws {
    runtime.context.evaluateScript(
      "for (let i = 0; i < 224; i++) IrisSql.run('INSERT INTO notes (id, title) VALUES (?, ?)', ['page-' + i, 'Synthetic page ' + i])"
    )
    try #require(runtime.context.exception == nil)
  }

  var requests: [String] {
    runtime.context.evaluateScript("exportRequests")?.toArray() as? [String] ?? []
  }
  func holdNext(_ method: String, onHeld: @escaping @Sendable () -> Void = {}) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    heldStart = stream
    heldContinuation = continuation
    heldMethod = method
    // JSC emits only after the actual request has installed its release closure.
    // Buffer the event even if admission precedes waitUntilHeld's suspension.
    let started: @convention(block) () -> Void = {
      continuation.yield(())
      continuation.finish()
      onHeld()
    }
    runtime.context.setObject(started, forKeyedSubscript: "exportRequestHeld" as NSString)
    runtime.context.setObject(method, forKeyedSubscript: "exportHeldMethod" as NSString)
  }

  func release() {
    // Disarm too: a failed admission wait must not trap a request arriving later.
    runtime.context.evaluateScript("exportHeldMethod = null; releaseExportRequest?.()")
    runtime.context.setObject(nil, forKeyedSubscript: "exportRequestHeld" as NSString)
    heldContinuation?.finish()
    heldContinuation = nil
    heldStart = nil
    heldMethod = nil
  }

  func waitUntilHeld(watchdogAfter: Duration = .seconds(10)) async throws {
    let stream = try #require(heldStart)
    let continuation = try #require(heldContinuation)
    let method = try #require(heldMethod)
    // This is a diagnostic watchdog, not an admission polling interval or a
    // performance assertion. Keep the existing bound while removing busy JSC reads.
    let watchdog = Task {
      do { try await Task.sleep(for: watchdogAfter) } catch { return }
      continuation.finish()
    }
    defer { watchdog.cancel() }
    do {
      var iterator = stream.makeAsyncIterator()
      let started: Void? = await iterator.next()
      try #require(
        started != nil,
        Comment(
          rawValue:
            "Held \(method) request did not signal admission; requests=\(requests), loading=\(model.loading), JSC=\(runtime.context.exception?.toString() ?? "none")"
        ))
      // Preserve the fixture-state assertion without repeatedly crossing JSC.
      try #require(
        runtime.context.evaluateScript("releaseExportRequest !== null")?.toBool() == true)
    } catch {
      release()
      // Do not await close on the admission queue that may have stalled.
      // Rethrow promptly so the caller's cancellation defer can unwind too.
      throw error
    }
  }
}

/// Separate observer proves actual fixture entry before testing a buffered or absent notification.
private struct ExportAdmissionObserver: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func signal() {
    continuation.yield(())
    continuation.finish()
  }

  func wait() async -> Bool {
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = stream.makeAsyncIterator()
    return await iterator.next() != nil
  }
}
