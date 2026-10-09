import Foundation
import Testing

@testable import IrisKit

@MainActor
struct NativeReadCancellationTests {
  @Test(arguments: [0, 3, 6])
  func queuedCancellationSkipsOnlyCancelledReads(cancelledCount: Int) async throws {
    let fixture = try await ReadAdmissionFixture()
    defer { fixture.release() }
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var submitted: [Int] = []
    let reads = (0..<6).map { index in
      Task {
        submitted.append(index)
        if index.isMultiple(of: 2) {
          _ = try await fixture.workspace.catalog()
        } else {
          _ = try await fixture.workspace.rows(table: "notes")
        }
      }
    }
    try await waitUntil { submitted.count == reads.count }
    let leaving = Array(reads.prefix(cancelledCount))
    await Task.detached { for task in leaving { task.cancel() } }.value
    fixture.release()
    _ = try await blocker.value
    for (index, read) in reads.enumerated() {
      if index < cancelledCount {
        await #expect(throws: CancellationError.self) { try await read.value }
      } else {
        try await read.value
      }
    }
    #expect(
      fixture.admitted
        == submitted.filter { $0 >= cancelledCount }.map {
          $0.isMultiple(of: 2) ? "catalog" : "rows"
        })
    // Draining an entirely cancelled queue must leave admission usable.
    #expect(!(try await fixture.workspace.catalog()).tables.isEmpty)
    try await fixture.workspace.close()
  }

  @Test(arguments: ["catalog", "rows"])
  func alreadyCancelledReadDoesNotEnqueue(method: String) async throws {
    let fixture = try await ReadAdmissionFixture()
    var proceed: CheckedContinuation<Void, Never>?
    let read = Task {
      await withCheckedContinuation { proceed = $0 }
      if method == "catalog" {
        _ = try await fixture.workspace.catalog()
      } else {
        _ = try await fixture.workspace.rows(table: "notes")
      }
    }
    try await waitUntil { proceed != nil }
    read.cancel()
    proceed?.resume()
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(fixture.admitted.isEmpty)
    try await fixture.workspace.close()
  }

  @Test func cancelledReadsWaitingForAnotherInstanceReleaseTheirFileTurn() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("synthetic.sqlite").path
    let first = try await ReadAdmissionFixture(path: path)
    let second = try await ReadAdmissionFixture(path: path, seed: false)
    let third = try await ReadAdmissionFixture(path: path, seed: false)
    defer {
      first.release()
      second.release()
      third.release()
    }
    first.holdNext()
    let blocker = Task { try await first.workspace.catalog() }
    try await first.waitUntilHeld()
    var submitted = 0
    let cancelled = (0..<4).map { _ in
      Task {
        submitted += 1
        return try await second.workspace.rows(table: "notes")
      }
    }
    try await waitUntil { submitted == cancelled.count }
    for task in cancelled { task.cancel() }
    var liveFinished = 0
    let thirdLive = Task {
      defer { liveFinished += 1 }
      return try await third.workspace.catalog()
    }
    let firstLive = Task {
      defer { liveFinished += 1 }
      return try await first.workspace.rows(table: "notes")
    }
    first.release()
    _ = try await blocker.value
    for read in cancelled {
      await #expect(throws: CancellationError.self) { try await read.value }
    }
    try await waitUntil { liveFinished == 2 }
    #expect(!(try await thirdLive.value).tables.isEmpty)
    #expect(!(try await firstLive.value).isEmpty)
    #expect(second.admitted.isEmpty)
    #expect(!(try await second.workspace.catalog()).tables.isEmpty)
    try await first.workspace.close()
    try await second.workspace.close()
    try await third.workspace.close()
  }

  @Test func cancellationAfterAdmissionStillCompletesOwnedTransactionAndCallback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("synthetic.sqlite").path
    let first = try await ReadAdmissionFixture(path: path)
    let second = try await ReadAdmissionFixture(path: path, seed: false)
    defer {
      first.release()
      second.release()
    }
    first.holdNext()
    var finished = false
    let admitted = Task {
      defer { finished = true }
      return try await first.workspace.rows(table: "notes")
    }
    try await first.waitUntilHeld()
    first.runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE notes SET title='Synthetic committed title'\")")
    try #require(first.runtime.context.exception == nil)
    admitted.cancel()
    var waiting = false
    let follower = Task {
      waiting = true
      return try await second.workspace.rows(table: "notes")
    }
    try await waitUntil { waiting }
    #expect(!finished && second.admitted.isEmpty, "Cancellation must not release an admitted owner")
    first.release()
    let result = try await admitted.value
    #expect(result.first?.label == "Synthetic committed title")
    #expect(try await follower.value.first?.label == "Synthetic committed title")
    #expect(first.runtime.context.exception == nil)
    try await first.workspace.close()
    try await second.workspace.close()
  }

  @Test func cancellingQueuedWriteAndCloseDoesNotDiscardEitherOperation() async throws {
    let fixture = try await ReadAdmissionFixture()
    let original = try #require(try await fixture.workspace.rows(table: "notes").first?.record)
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var submitted = 0
    let write = Task {
      submitted += 1
      return try await fixture.workspace.write(
        table: "notes", patch: ["id": original["id"]!, "title": .string("Kept cancelled write")],
        expectedUpdatedAt: original["updated_at"]?.text)
    }
    try await waitUntil { submitted == 1 }
    let close = Task {
      submitted += 1
      try await fixture.workspace.close()
    }
    try await waitUntil { submitted == 2 }
    write.cancel()
    close.cancel()
    fixture.release()
    _ = try await blocker.value
    #expect(try await write.value["title"] == .string("Kept cancelled write"))
    try await close.value
    #expect(fixture.admitted == ["write"])
    await #expect(throws: WorkspaceError.self) { try await fixture.workspace.catalog() }
  }

  private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(
      condition(), "Read admission barrier was not reached", sourceLocation: sourceLocation)
  }
}

@MainActor
struct WorkspaceReadCancellationTests {
  @Test(arguments: [false, true])
  func failedOrCancelledTestReleasesItsAdmittedRequest(cancelled: Bool) async throws {
    enum FixtureFailure: Error { case expected }
    var retained: ReadAdmissionFixture?
    let operation = Task { @MainActor in
      try await withReadAdmissionFixture { fixture in
        retained = fixture
        fixture.holdNext("rows")
        _ = fixture.track(Task { try await fixture.workspace.rows(table: "notes") })
        try await fixture.waitUntilHeld()
        if cancelled {
          withUnsafeCurrentTask { $0?.cancel() }
          try Task.checkCancellation()
        }
        throw FixtureFailure.expected
      }
    }
    do {
      try await operation.value
      Issue.record("The fixture body must fail")
    } catch {
      #expect(cancelled ? error is CancellationError : error is FixtureFailure)
    }
    let fixture = try #require(retained)
    try #require(fixture.didClose, "Failed test must close its released fixture")
    #expect(!fixture.holding)
    await #expect(throws: WorkspaceError.self) { try await fixture.workspace.catalog() }
  }

  @Test(arguments: [false, true], [false, true])
  func cancelledReloadPreservesVisibleState(afterAdmission: Bool, fails: Bool) async throws {
    try await withReadAdmissionFixture { fixture in
      let model = try await makeModel(fixture)
      let original = model.rows
      let undo = model.undoAction
      model.error = "Previous load error"
      fixture.holdNext(afterAdmission ? "rows" : "writeability")
      let reload = fixture.track(Task { await model.reload() })
      defer { fixture.release() }
      try await fixture.waitUntilHeld()
      fixture.runtime.context.evaluateScript(
        fails
          ? "IrisSql.run(\"DROP TABLE notes\")"
          : "IrisSql.run(\"UPDATE notes SET title='Changed while refreshing'\")")
      try #require(fixture.runtime.context.exception == nil)
      reload.cancel()
      fixture.release()
      await reload.value
      #expect(model.rows == original)
      #expect(model.error == "Previous load error")
      #expect(model.undoAction == undo)
      #expect(!model.loading)
    }
  }

  @Test func cancelledCommittedSaveAndUndoReconcileVisibleRows() async throws {
    try await withReadAdmissionFixture { fixture in
      let model = try await makeModel(fixture)
      let original = try #require(model.rows.first?.record)
      let context = try #require(model.editingContext)
      fixture.holdNext("write")
      let save = fixture.track(
        Task {
          try await model.save(
            ["id": original["id"]!, "title": .string("Committed despite cancellation")],
            original: original, context: context)
        })
      defer { fixture.release() }
      try await fixture.waitUntilHeld()
      save.cancel()
      fixture.release()
      #expect(try await save.value["title"] == .string("Committed despite cancellation"))
      #expect(model.rows.first?.label == "Committed despite cancellation")
      #expect(model.error == nil && !model.loading)
      let action = try #require(model.undoAction)
      fixture.holdNext("undo")
      let undo = fixture.track(Task { try await model.undo(action, context: context) })
      try await fixture.waitUntilHeld()
      undo.cancel()
      fixture.release()
      #expect(try await undo.value["title"] == original["title"])
      #expect(model.rows.first?.record["title"] == original["title"])
      #expect(model.error == nil && !model.loading)
    }
  }

  @Test(arguments: ["table", "query", "workspace"])
  func committedSaveDoesNotRefreshReplacementContext(change: String) async throws {
    try await withReadAdmissionFixture { fixture in
      let replacement = try await ReadAdmissionFixture()
      fixture.addCleanup { try await replacement.workspace.close() }
      let model = try await makeModel(fixture)
      let original = try #require(model.rows.first?.record)
      let context = try #require(model.editingContext)
      fixture.holdNext("write")
      let save = fixture.track(
        Task {
          try await model.save(
            ["id": original["id"]!, "title": .string("Saved in original context")],
            original: original, context: context)
        })
      defer { fixture.release() }
      try await fixture.waitUntilHeld()
      if change == "table" {
        model.table = "topics"
      } else if change == "query" {
        model.search = "No matching synthetic record"
      } else {
        model.client = replacement.workspace
      }
      // Clear before the replacement can complete on its independent workspace.
      // Observing its start must not discard an already-admitted row request.
      fixture.clearTrace()
      replacement.clearTrace()
      let replacementStarted = ReadAdmissionSignal()
      let reload = fixture.track(
        Task {
          replacementStarted.signal()
          await model.reload()
        })
      try #require(await replacementStarted.wait(), "Replacement reload task did not start")
      save.cancel()
      fixture.release()
      _ = try await save.value
      await reload.value
      #expect(model.error == nil && !model.loading)
      let rowRequests = (fixture.admitted + replacement.admitted).filter { $0 == "rows" }.count
      #expect(
        rowRequests == 1,
        "The committed old save must not start a second refresh in the new context")
      if change == "query" {
        #expect(model.rows.isEmpty)
      } else {
        #expect(!model.rows.isEmpty && model.rows.first?.label != "Saved in original context")
      }
    }
  }

  @Test func cancelledOldReloadCannotPublishOverNewTable() async throws {
    try await withReadAdmissionFixture { fixture in
      let model = try await makeModel(fixture)
      fixture.holdNext("rows")
      let old = fixture.track(Task { await model.reload() })
      defer { fixture.release() }
      try await fixture.waitUntilHeld()
      model.table = "topics"
      let replacementStarted = ReadAdmissionSignal()
      let current = fixture.track(
        Task {
          replacementStarted.signal()
          await model.reload()
        })
      try #require(await replacementStarted.wait(), "Replacement table reload task did not start")
      old.cancel()
      fixture.release()
      await old.value
      await current.value
      #expect(model.table == "topics")
      #expect(!model.rows.isEmpty && model.rows.allSatisfy { $0.record["body"] == nil })
      #expect(model.error == nil && !model.loading)
    }
  }

  private func makeModel(_ fixture: ReadAdmissionFixture) async throws -> WorkspaceModel {
    let model = WorkspaceModel()
    model.client = fixture.workspace
    model.catalog = try await fixture.workspace.catalog()
    model.table = "notes"
    await model.reload()
    try #require(!model.rows.isEmpty)
    fixture.clearTrace()
    return model
  }
}

@MainActor
struct ReferenceReadAdmissionTests {
  @Test(arguments: ["serviceNotifications", "sync"])
  func serviceBarrierDoesNotAdmitAnEntirePassiveBacklog(method: String) async throws {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var submitted = 0
    let labels = (0..<12).map { _ in
      Task {
        submitted += 1
        return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
      }
    }
    try await waitUntil { submitted == labels.count }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadAdmissionTransport.self]
    let transport = try HubTransport(
      endpoint: "https://read-admission.invalid", token: "synthetic", configuration: configuration)
    var remoteQueued = false
    let remote = Task {
      remoteQueued = true
      if method == "sync" {
        _ = try await fixture.workspace.sync(using: transport)
      } else {
        _ = try await fixture.workspace.notifications(using: transport)
      }
    }
    try await waitUntil { remoteQueued }
    var navigationQueued = false
    let navigation = Task {
      navigationQueued = true
      return try await NativeDestinationResolver(workspace: fixture.workspace).resolve(
        NativeDestination(table: "topics"), isCurrent: { true })
    }
    try await waitUntil { navigationQueued }
    fixture.release()
    _ = try await blocker.value
    #expect(try await navigation.value.destination.table == "topics")
    let openingIndex = try #require(fixture.admitted.firstIndex(of: "catalog"))
    #expect(fixture.admitted[..<openingIndex].filter { $0 == "rows" }.count <= 1)
    #expect(fixture.admitted.prefix(3) == ["rows", method, "catalog"])
    for label in labels { #expect(!(try await label.value).isEmpty) }
    _ = await remote.result
    try await fixture.workspace.close()
  }

  @Test func cancelledPassiveWaiterFinishesBeforeActiveTransactionAndDoesNotConsumeNextRead()
    async throws
  {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext("rows")
    let active = Task {
      try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    var submitted = false
    var cancelledFinished = false
    let cancelled = Task {
      defer { cancelledFinished = true }
      submitted = true
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { submitted }
    await Task.detached { cancelled.cancel() }.value
    try await waitUntil { cancelledFinished }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(fixture.holding && fixture.admitted == ["rows"])
    let live = Task {
      try await fixture.workspace.referenceRows(view: CoreView(table: "topics"))
    }
    fixture.release()
    #expect(!(try await active.value).isEmpty)
    #expect(!(try await live.value).isEmpty)
    #expect(fixture.admitted == ["rows", "rows"])
    try await fixture.workspace.close()
  }

  @Test func failedPassiveReadReleasesWaitingLabels() async throws {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext("rows")
    let failed = Task {
      try await fixture.workspace.referenceRows(view: CoreView(table: "missing_fixture_table"))
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    let live = Task {
      try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    fixture.release()
    await #expect(throws: WorkspaceError.self) { try await failed.value }
    #expect(!(try await live.value).isEmpty)
    try await fixture.workspace.close()
  }

  @Test func cancellationAfterPassivePermitHandoffReleasesItForNextWaiter() async throws {
    let fixture = try await ReadAdmissionFixture()
    var cancelled: Task<[WorkspaceRow], Error>?
    fixture.holdNext("rows")
    let active = Task {
      // referenceRows hands its permit to the next waiter before returning.
      // Cancel that waiter in this same actor turn, before it can resume.
      defer { cancelled?.cancel() }
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    var submitted = 0
    cancelled = Task {
      submitted += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { submitted == 1 }
    let live = Task {
      submitted += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "topics"))
    }
    try await waitUntil { submitted == 2 }
    fixture.release()
    #expect(!(try await active.value).isEmpty)
    let cancelledTask = try #require(cancelled)
    await #expect(throws: CancellationError.self) { try await cancelledTask.value }
    #expect(!(try await live.value).isEmpty)
    #expect(fixture.admitted == ["rows", "rows"])
    try await fixture.workspace.close()
  }

  @Test func closeDrainsUnsubmittedPassiveLabelsWithoutCallingCore() async throws {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext("rows")
    let active = Task {
      try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    var submitted = 0
    let waiting = (0..<6).map { _ in
      Task {
        submitted += 1
        return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
      }
    }
    try await waitUntil { submitted == waiting.count }
    var closing = false
    let close = Task {
      closing = true
      try await fixture.workspace.close()
    }
    try await waitUntil { closing }
    active.cancel()
    #expect(fixture.holding, "An admitted transaction must finish despite view cancellation")
    fixture.release()
    #expect(!(try await active.value).isEmpty)
    try await close.value
    for label in waiting {
      await #expect(throws: WorkspaceError.self) { try await label.value }
    }
    #expect(fixture.admitted == ["rows"])
  }

  @Test func liveReferenceLabelsYieldToDestinationBeforeOldViewLeaves() async throws {
    let fixture = try await ReadAdmissionFixture()
    let row = try #require(try await fixture.workspace.rows(table: "notes").first)
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var enqueued = 0
    let labels = (0..<8).map { _ in
      Task {
        await NativePropertyValue.referenceLabels(
          field: CatalogField(property: ["type": .string("ref"), "ref_table": .string("notes")]),
          value: row.id
        ) { view in
          enqueued += 1
          return try await fixture.workspace.referenceRows(view: view)
        }
      }
    }
    try await waitUntil { enqueued == labels.count }
    var navigating = false
    let navigation = Task {
      navigating = true
      return try await NativeDestinationResolver(workspace: fixture.workspace).resolve(
        NativeDestination(table: "topics"), isCurrent: { true })
    }
    try await waitUntil { navigating }
    fixture.release()
    _ = try await blocker.value
    #expect(try await navigation.value.destination.table == "topics")
    #expect(
      fixture.admitted.first == "catalog",
      "Mounted old reference labels must not block destination resolution")
    for label in labels { #expect(await label.value == row.label) }
    try await fixture.workspace.close()
  }

  @Test(arguments: [false, true])
  func activatedTablePublishesRowsAndCanSaveWithoutWaitingForLabels(cancelOnActivation: Bool)
    async throws
  {
    let fixture = try await ReadAdmissionFixture()
    let model = WorkspaceModel()
    model.client = fixture.workspace
    model.catalog = try await fixture.workspace.catalog()
    model.table = "notes"
    await model.reload()
    let row = try #require(model.rows.first)
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var enqueued = 0
    var completedLabels: Set<Int> = []
    let labels = (0..<20).map { index in
      Task {
        let result = await NativePropertyValue.referenceLabels(
          field: CatalogField(property: ["type": .string("ref"), "ref_table": .string("notes")]),
          value: row.id
        ) { view in
          enqueued += 1
          return try await fixture.workspace.referenceRows(view: view)
        }
        completedLabels.insert(index)
        return result
      }
    }
    try await waitUntil { enqueued == labels.count }
    var navigating = false
    let navigation = Task {
      navigating = true
      return try await NativeDestinationResolver(workspace: fixture.workspace).resolve(
        NativeDestination(table: "topics"), isCurrent: { true })
    }
    try await waitUntil { navigating }
    fixture.release()
    _ = try await blocker.value
    let context = try model.activateDestination(
      try await navigation.value,
      workspace: fixture.workspace, generation: model.workspaceGeneration)
    let completedBeforeCancellation = completedLabels
    if cancelOnActivation { for label in labels { label.cancel() } }
    await model.reload()
    #expect(fixture.admitted.first == "catalog")
    #expect(
      fixture.admitted.filter { $0 == "rows" }.count < labels.count,
      "New rows must publish before the passive-label backlog drains, even during delayed teardown")
    #expect(model.table == "topics" && !model.loading && model.error == nil)
    #expect(model.writeability?.writable == true)
    let original = try #require(model.rows.first?.record)
    _ = try await model.save(
      ["id": original["id"]!, "title": .string("Saved after navigation")],
      original: original, context: context)
    #expect(model.rows.first?.label == "Saved after navigation")
    #expect(
      fixture.admitted.filter { $0 == "rows" }.count < labels.count,
      "Saving and its refresh must also complete before the passive-label backlog drains")
    for (index, label) in labels.enumerated() {
      let cancelledBeforeCompletion =
        cancelOnActivation && !completedBeforeCancellation.contains(index)
      #expect(await label.value == (cancelledBeforeCompletion ? "Unavailable" : row.label))
    }
    try await fixture.workspace.close()
  }

  @Test func foregroundWritesAndReadsPreserveTheirOrderAroundPassiveLabels() async throws {
    let fixture = try await ReadAdmissionFixture()
    let original = try #require(try await fixture.workspace.rows(table: "notes").first?.record)
    fixture.clearTrace()
    fixture.holdNext("rows")
    var queued = 0
    let before = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    let write = Task {
      queued += 1
      return try await fixture.workspace.write(
        table: "notes",
        patch: ["id": original["id"]!, "title": .string("Barrier committed")],
        expectedUpdatedAt: original["updated_at"]?.text)
    }
    try await waitUntil { queued == 2 }
    let after = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { queued == 3 }
    let secondWrite = Task {
      queued += 1
      return try await fixture.workspace.write(
        table: "topics",
        patch: ["title": .string("Second foreground write")])
    }
    try await waitUntil { queued == 4 }
    let navigation = Task {
      queued += 1
      return try await fixture.workspace.rows(table: "notes")
    }
    try await waitUntil { queued == 5 }
    fixture.release()
    #expect(try await before.value.first?.record["title"] == original["title"])
    _ = try await write.value
    #expect(try await secondWrite.value["title"] == .string("Second foreground write"))
    #expect(try await navigation.value.first?.label == "Barrier committed")
    _ = try await after.value
    #expect(fixture.admitted == ["rows", "write", "write", "rows", "rows"])
    let ids = fixture.runtime.context.evaluateScript("readAdmissionIDs")?.toArray() as? [Int] ?? []
    // Waiting passive callers receive a request identity only when submitted.
    #expect(ids.count == 5 && ids[1] < ids[2] && ids[2] < ids[3])
    try await fixture.workspace.close()
  }

  @Test(arguments: ["serviceNotifications", "sync"])
  func transportRequestsStayBehindEarlierLabelsAndAheadOfLaterForegroundReads(method: String)
    async throws
  {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadAdmissionTransport.self]
    let transport = try HubTransport(
      endpoint: "https://read-admission.invalid", token: "synthetic", configuration: configuration)
    var queued = 0
    let before = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { queued == 1 }
    let remote = Task {
      queued += 1
      if method == "sync" {
        _ = try await fixture.workspace.sync(using: transport)
      } else {
        _ = try await fixture.workspace.notifications(using: transport)
      }
    }
    try await waitUntil { queued == 2 }
    let after = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { queued == 3 }
    let navigation = Task {
      queued += 1
      return try await fixture.workspace.catalog()
    }
    try await waitUntil { queued == 4 }
    fixture.release()
    _ = try await blocker.value
    #expect(!(try await before.value).isEmpty)
    _ = await remote.result
    #expect(!(try await navigation.value).tables.isEmpty)
    _ = try await after.value
    #expect(fixture.admitted == ["rows", method, "catalog", "rows"])
    try await fixture.workspace.close()
  }

  @Test func foregroundReadCannotOvertakeClose() async throws {
    let fixture = try await ReadAdmissionFixture()
    fixture.holdNext()
    let blocker = Task { try await fixture.workspace.catalog() }
    defer { fixture.release() }
    try await fixture.waitUntilHeld()
    fixture.clearTrace()
    var queued = 0
    let before = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { queued == 1 }
    let close = Task {
      queued += 1
      try await fixture.workspace.close()
    }
    try await waitUntil { queued == 2 }
    let after = Task {
      queued += 1
      return try await fixture.workspace.referenceRows(view: CoreView(table: "notes"))
    }
    try await waitUntil { queued == 3 }
    let navigation = Task {
      queued += 1
      return try await fixture.workspace.catalog()
    }
    try await waitUntil { queued == 4 }
    fixture.release()
    _ = try await blocker.value
    #expect(!(try await before.value).isEmpty)
    try await close.value
    await #expect(throws: WorkspaceError.self) { try await after.value }
    await #expect(throws: WorkspaceError.self) { try await navigation.value }
    #expect(fixture.admitted == ["rows"])
  }

  private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(
      condition(), "Reference admission barrier was not reached", sourceLocation: sourceLocation)
  }
}

@MainActor private final class ReadAdmissionFixture {
  let runtime: IrisCoreRuntime
  let workspace: NativeWorkspace
  private(set) var didClose = false
  private var heldSignal: ReadAdmissionSignal?
  private var expectedMethod: String?
  private var cancellations: [() -> Void] = []
  private var completions: [() async -> Void] = []
  private var extraCleanup: [() async throws -> Void] = []

  init(path: String = ":memory:", seed: Bool = true) async throws {
    runtime = try IrisCoreRuntime()
    workspace = try NativeWorkspace(path: path, runtime: runtime)
    if seed { try await workspace.createSample() }
    runtime.context.evaluateScript(
      #"""
      globalThis.readAdmissionTrace = [];
      globalThis.readAdmissionIDs = [];
      globalThis.holdNextRead = false;
      globalThis.heldReadMethod = null;
      globalThis.releaseRead = null;
      const admissionRequest = IrisNative.request;
      IrisNative.request = function(id, method, args) {
        readAdmissionTrace.push(method);
        readAdmissionIDs.push(id);
        if (!holdNextRead || (heldReadMethod !== null && method !== heldReadMethod)) return admissionRequest(id, method, args);
        holdNextRead = false;
        IrisSql.begin();
        globalThis.releaseRead = () => {
          IrisSql.commit();
          releaseRead = null;
          admissionRequest(id, method, args);
        };
        readAdmissionReached();
      };
      """#)
    try #require(runtime.context.exception == nil)
  }

  var admitted: [String] {
    runtime.context.evaluateScript("readAdmissionTrace")?.toArray() as? [String] ?? []
  }
  var holding: Bool {
    runtime.context.evaluateScript("releaseRead !== null")?.toBool() == true
  }
  func holdNext(_ method: String? = nil) {
    let signal = ReadAdmissionSignal()
    heldSignal = signal
    expectedMethod = method
    let reached: @convention(block) () -> Void = { signal.signal() }
    runtime.context.setObject(reached, forKeyedSubscript: "readAdmissionReached" as NSString)
    runtime.context.setObject(
      method ?? NSNull() as Any, forKeyedSubscript: "heldReadMethod" as NSString)
    runtime.context.evaluateScript("holdNextRead = true")
  }
  func clearTrace() {
    runtime.context.evaluateScript("readAdmissionTrace = []; readAdmissionIDs = []")
  }
  func waitUntilHeld(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let signal = try #require(
      heldSignal, "Arm the held request first", sourceLocation: sourceLocation)
    let reached = await signal.wait()
    try Task.checkCancellation()
    try #require(
      reached,
      "JSC admission watchdog expired: expected=\(expectedMethod ?? "any"), admitted=\(admitted), exception=\(String(describing: runtime.context.exception))",
      sourceLocation: sourceLocation)
    try #require(
      holding, "Admission signal must follow releaseRead installation",
      sourceLocation: sourceLocation)
  }
  func release() {
    // Disarm an admission that has not happened yet as well as releasing a held one.
    runtime.context.evaluateScript("holdNextRead = false; releaseRead?.()")
  }

  func track<T: Sendable, Failure: Error>(_ task: Task<T, Failure>) -> Task<T, Failure> {
    cancellations.append { task.cancel() }
    completions.append { _ = await task.result }
    return task
  }

  func addCleanup(_ cleanup: @escaping () async throws -> Void) { extraCleanup.append(cleanup) }

  func cleanUp(sourceLocation: SourceLocation) async {
    // The cancellation-independent supervisor bounds teardown even when the test
    // fails before JSC admission. Never await a possibly stuck queue unboundedly.
    let supervisor = Task { @MainActor in
      for cancel in cancellations { cancel() }
      release()
      let finished = ReadAdmissionSignal()
      let closing = Task { @MainActor in
        defer { finished.signal() }
        for completion in completions { await completion() }
        do {
          try await workspace.close()
          didClose = true
        } catch {
          Issue.record(error, sourceLocation: sourceLocation)
        }
        for cleanup in extraCleanup {
          do { try await cleanup() } catch { Issue.record(error, sourceLocation: sourceLocation) }
        }
      }
      let completed = await finished.wait()
      if !completed { closing.cancel() }
      #expect(
        completed, "Read fixture cleanup exceeded 20 seconds; outstanding fixture retained",
        sourceLocation: sourceLocation)
    }
    await supervisor.value
  }
}

@MainActor private func withReadAdmissionFixture(
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: (ReadAdmissionFixture) async throws -> Void
) async throws {
  let fixture = try await ReadAdmissionFixture()
  do { try await body(fixture) } catch {
    await fixture.cleanUp(sourceLocation: sourceLocation)
    throw error
  }
  await fixture.cleanUp(sourceLocation: sourceLocation)
}

private struct ReadAdmissionSignal: Sendable {
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
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = stream.makeAsyncIterator()
    return await iterator.next() != nil
  }
}

private final class ReadAdmissionTransport: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
