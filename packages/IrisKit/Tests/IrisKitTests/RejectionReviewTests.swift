import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct RejectionReviewTests {
  private func fixture() async throws -> (
    URL, WorkspaceModel, NativeWorkspace, IrisCoreRuntime, CoreRejectedEdit
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("local.sqlite")
    let model = WorkspaceModel(localURL: { path })
    await model.open()
    try await model.client?.close()
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: path.path, runtime: runtime)
    model.client = workspace
    model.catalog = try await workspace.catalog()
    model.table = "topics"
    model.search = "Keep source query"
    let row = try #require(try await workspace.rows(table: "notes").first)
    let submitted = row.record.merging([
      "title": .string("Rejected title"), "body": .string("Rejected body"),
    ]) { _, next in next }
    let entry = CoreRejectedEdit(
      table: "notes", rowID: row.id, submitted: submitted,
      errors: [["id": .string(row.id), "message": .string("Synthetic rejection")]])
    _ = try await workspace.status()
    runtime.context.setObject(
      String(decoding: try JSONEncoder().encode(submitted), as: UTF8.self),
      forKeyedSubscript: "reviewSubmission" as NSString)
    runtime.context.evaluateScript(
      #"IrisSql.run('INSERT INTO _core_rejected(tbl,row_id,row,errors) VALUES (?,?,?,?)', ['notes',JSON.parse(reviewSubmission).id,reviewSubmission,JSON.stringify([{id:JSON.parse(reviewSubmission).id,message:'Synthetic rejection'}])]);"#
    )
    #expect(runtime.context.exception == nil)
    return (root, model, workspace, runtime, entry)
  }

  @Test(arguments: [false, true])
  func preparingFreshActiveOrTrashedRowPersistsBeforeAnyNavigation(_ trashed: Bool) async throws {
    let (root, model, workspace, runtime, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let current = try await workspace.write(
      table: "notes",
      patch: [
        "id": .string(entry.rowID), "title": .string("Current title"),
        "body": .string("Current body"), "deleted_at": trashed ? .bool(true) : .null,
      ], expectedUpdatedAt: entry.submitted["updated_at"]?.text)
    runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE catalog_properties SET immutable=1 WHERE tbl='notes' AND col='title'\");"
    )
    #expect(runtime.context.exception == nil)
    let query = model.queryKey
    let catalog = model.catalog
    let recents = model.recents?.destinations
    let prepared = try await model.prepareRejectionReview(
      entry, workspace: workspace,
      generation: model.workspaceGeneration)
    #expect(model.table == "topics" && model.queryKey == query && model.catalog == catalog)
    #expect(model.recents?.destinations == recents)
    #expect(prepared.editor.draft.original == current)
    #expect(prepared.editor.draft.fields.map(\.id) == ["status", "body", "topic", "related"])
    #expect(prepared.editor.draft.values["title"] == nil)
    #expect(prepared.editor.draft.values["body"] == "Rejected body")
    #expect(prepared.editor.autosavePaused && prepared.editor.isTrashed == trashed)
    let store = try #require(prepared.context.draftStore)
    let journal = try #require(try store.load(table: "notes", recordID: entry.rowID))
    #expect(journal.draft.original == current && journal.autosavePaused == true)
    try model.activateRejectionReview(prepared)
    #expect(model.table == "notes" && model.trash == trashed && model.search.isEmpty)
    if trashed {
      try await prepared.editor.saveAll(["id": .string(entry.rowID), "deleted_at": .null])
      #expect(prepared.editor.draft.values["body"] == "Rejected body")
    }
    prepared.editor.setValue("Corrected body", for: "body")
    try await prepared.editor.saveAll()
    #expect(
      try await workspace.rows(table: "notes").first?.record["body"] == .string("Corrected body"))
    #expect(try await workspace.status().rejected == 1)
    await model.close()
  }

  @Test(arguments: ["missing", "readonly", "journal"])
  func failedPreparationKeepsSourceStateAndDurableRejection(_ failure: String) async throws {
    let (root, model, workspace, runtime, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try #require(model.editingContext?.draftStore)
    if failure == "missing" { runtime.context.evaluateScript("IrisSql.run('DELETE FROM notes');") }
    if failure == "readonly" {
      runtime.context.evaluateScript(
        "IrisSql.run(\"UPDATE catalog_tables SET kind='system' WHERE id='notes'\");")
    }
    if failure == "journal" {
      try FileManager.default.createDirectory(
        at: store.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("unreadable".utf8).write(to: store.directory)
    }
    let query = model.queryKey
    let catalog = model.catalog
    let recents = model.recents?.destinations
    await #expect(throws: (any Error).self) {
      _ = try await model.prepareRejectionReview(
        entry, workspace: workspace, generation: model.workspaceGeneration)
    }
    #expect(model.table == "topics" && model.queryKey == query && model.catalog == catalog)
    #expect(model.recents?.destinations == recents)
    #expect(try await workspace.status().rejected == 1)
    if failure == "journal" {
      #expect(try Data(contentsOf: store.directory) == Data("unreadable".utf8))
    } else {
      #expect(try store.all().isEmpty)
    }
    await model.close()
  }

  @Test(arguments: ["catalogRevision", "rows", "writeability"], [false, true])
  func changedQueryDiscardsDelayedSuccessAndFailure(_ method: String, _ fail: Bool) async throws {
    let (root, model, workspace, runtime, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try #require(model.editingContext?.draftStore)
    runtime.context.setObject(method, forKeyedSubscript: "heldMethod" as NSString)
    runtime.context.evaluateScript(
      "var beforeReview = IrisNative.request; var heldReview = null; IrisNative.request = (id,method,args) => { if(method === heldMethod) heldReview = [id,method,args]; else beforeReview(id,method,args); };"
    )
    var finished = false
    let task = Task {
      defer { finished = true }
      return try await model.prepareRejectionReview(
        entry, workspace: workspace, generation: model.workspaceGeneration)
    }
    while !finished && runtime.context.evaluateScript("heldReview === null")?.toBool() == true {
      await Task.yield()
    }
    #expect(!finished)
    model.search = "New source query"
    let query = model.queryKey
    runtime.context.evaluateScript(
      fail
        ? "IrisNative.request = beforeReview; __irisFinish(heldReview[0], JSON.stringify({error:'Obsolete fixture failure',violations:[]}));"
        : "IrisNative.request = beforeReview; beforeReview(...heldReview);")
    do {
      _ = try await task.value
      Issue.record("Stale preparation must not publish")
    } catch { #expect(error is CancellationError) }
    #expect(model.queryKey == query)
    #expect(try store.all().isEmpty)
    await model.close()
  }

  @Test(arguments: ["sheet", "query", "workspace", "unicode"])
  func pendingSheetDismissalCannotActivateAfterItsContextChanges(_ change: String) async throws {
    let (root, model, workspace, _, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    if change == "unicode" {
      model.filters = [WorkspaceFilter(column: "title", operation: .eq, value: "\u{e9}")]
    }
    let prepared = try await model.prepareRejectionReview(
      entry, workspace: workspace,
      generation: model.workspaceGeneration)
    if change == "query" { model.search = "Different query" }
    if change == "workspace" { model.client = nil }
    if change == "unicode" {
      model.filters = [WorkspaceFilter(column: "title", operation: .eq, value: "e\u{301}")]
    }
    let query = model.queryKey
    let recents = model.recents?.destinations
    #expect(throws: (any Error).self) {
      try model.activateRejectionReview(prepared, isCurrent: { change != "sheet" })
    }
    #expect(model.queryKey == query && model.table == "topics")
    let store = try #require(prepared.context.draftStore)
    #expect(try store.all().count == 1)
    #expect(try store.all().first?.autosavePaused == true)
    #expect(model.recents?.destinations == recents)
    try await workspace.close()
    await model.close()
  }

  @Test func preparationAndActivationBothRespectTheExistingWriteGate() async throws {
    let (root, model, workspace, runtime, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try await model.prepareRejectionReview(
      entry, workspace: workspace,
      generation: model.workspaceGeneration)
    let context = try #require(model.editingContext)
    runtime.context.evaluateScript(
      "var beforeBusyReview = IrisNative.request; var busyReview = null; IrisNative.request = (id,method,args) => { if(method === 'write') busyReview=[id,method,args]; else beforeBusyReview(id,method,args); };"
    )
    let writing = Task {
      try await model.save(["title": .string("Pending topic")], original: nil, context: context)
    }
    while runtime.context.evaluateScript("busyReview === null")?.toBool() == true {
      await Task.yield()
    }
    #expect(throws: WorkspaceError.self) { try model.activateRejectionReview(prepared) }
    var preparationFinished = false
    let preparing = Task {
      defer { preparationFinished = true }
      return try await model.prepareRejectionReview(
        entry, workspace: workspace, generation: model.workspaceGeneration)
    }
    for _ in 0..<50 where !preparationFinished { await Task.yield() }
    #expect(preparationFinished)
    runtime.context.evaluateScript(
      "IrisNative.request = beforeBusyReview; beforeBusyReview(...busyReview);")
    _ = try await writing.value
    await #expect(throws: WorkspaceError.self) { _ = try await preparing.value }
    #expect(model.table == "topics")
    await model.close()
  }

  @Test(arguments: [false, true])
  func opaqueIdentitiesCannotSelectOrPrepareAnotherRecord(_ mismatch: Bool) async throws {
    let (root, model, workspace, runtime, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    runtime.context.evaluateScript(
      #"""
      IrisSql.run('INSERT INTO notes(id,title,body) VALUES (?,?,?)', ['\u00e9','First spelling','Keep first']);
      IrisSql.run('INSERT INTO notes(id,title,body) VALUES (?,?,?)', ['e\u0301','Second spelling','Keep second']);
      """#)
    #expect(runtime.context.exception == nil)
    let target = try #require(
      try await workspace.rows(table: "notes").first {
        $0.byteExactID == Data("e\u{301}".utf8)
      }?.record)
    let entry = CoreRejectedEdit(
      table: "notes", rowID: mismatch ? "\u{e9}" : "e\u{301}",
      submitted: target.merging(["body": .string("Review second")]) { _, next in next }, errors: [])
    if mismatch {
      await #expect(throws: WorkspaceError.self) {
        _ = try await model.prepareRejectionReview(
          entry, workspace: workspace, generation: model.workspaceGeneration)
      }
      #expect(try model.editingContext?.draftStore?.all().isEmpty == true)
    } else {
      let prepared = try await model.prepareRejectionReview(
        entry, workspace: workspace, generation: model.workspaceGeneration)
      #expect(
        Data(prepared.editor.draft.original?["id"]?.text.utf8 ?? "".utf8) == Data("e\u{301}".utf8))
      try model.activateRejectionReview(prepared)
      try await prepared.editor.saveAll()
      let rows = try await workspace.rows(table: "notes")
      #expect(
        rows.first { $0.byteExactID == Data("\u{e9}".utf8) }?.record["body"]
          == .string("Keep first"))
      #expect(
        rows.first { $0.byteExactID == Data("e\u{301}".utf8) }?.record["body"]
          == .string("Review second"))
    }
    await model.close()
  }
  @Test func inboxFactoryReopensDurableStateAndRejectsClosedWorkspaceReplies() async throws {
    let (root, model, workspace, runtime, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = try #require(model.makeRejectionInbox())
    await inbox.refresh()
    #expect(inbox.total == 1 && inbox.entries.count == 1)
    inbox.dispose()
    let reopened = try #require(model.makeRejectionInbox())
    runtime.context.evaluateScript(
      "var beforeInbox = IrisNative.request; var heldInbox = null; IrisNative.request = (id,method,args) => { if(method === 'rejections') heldInbox=[id,method,args]; else beforeInbox(id,method,args); };"
    )
    let refreshing = Task { await reopened.refresh() }
    while runtime.context.evaluateScript("heldInbox === null")?.toBool() == true {
      await Task.yield()
    }
    model.client = nil
    runtime.context.evaluateScript("IrisNative.request = beforeInbox; beforeInbox(...heldInbox);")
    await refreshing.value
    #expect(reopened.entries.isEmpty)
    #expect(model.makeRejectionInbox() == nil)
    try await workspace.close()
    await model.close()
  }

  @Test func preparationAndActivationNeverRecordRecentsBeforeEditorInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    let workspace = try #require(model.client)
    let recents = try #require(model.recents)
    let destination = NativeDestination(table: "topics")
    await recents.navigationSucceeded(destination)
    model.table = "topics"
    let row = try #require(try await workspace.rows(table: "notes").first)
    let entry = CoreRejectedEdit(
      table: "notes", rowID: row.id,
      submitted: row.record.merging(["body": .string("Review body")]) { _, next in next },
      errors: [])
    let prepared = try await model.prepareRejectionReview(
      entry, workspace: workspace, generation: model.workspaceGeneration)
    #expect(recents.destinations == [destination])
    try model.activateRejectionReview(prepared)
    #expect(recents.destinations == [destination])
    await model.close()
  }

  @Test func newerEditAfterPreparationRejectsCorrectionWithoutLosingReviewDraft() async throws {
    let (root, model, workspace, _, entry) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try await model.prepareRejectionReview(
      entry, workspace: workspace,
      generation: model.workspaceGeneration)
    try model.activateRejectionReview(prepared)
    let newer = try await workspace.write(
      table: "notes",
      patch: [
        "id": .string(entry.rowID), "body": .string("Newer saved body"),
      ], expectedUpdatedAt: prepared.editor.draft.original?["updated_at"]?.text)
    await #expect(throws: WorkspaceError.self) { try await prepared.editor.saveAll() }
    #expect(prepared.editor.draft.values["body"] == "Rejected body")
    #expect(prepared.editor.autosavePaused)
    #expect(prepared.editor.failure != nil)
    let stored = try #require(
      try prepared.context.draftStore?.load(table: "notes", recordID: entry.rowID))
    #expect(stored.draft.values["body"] == "Rejected body" && stored.autosavePaused == true)
    #expect(try await workspace.rows(table: "notes").first?.record == newer)
    #expect(try await workspace.status().rejected == 1)
    await model.close()
  }

}
