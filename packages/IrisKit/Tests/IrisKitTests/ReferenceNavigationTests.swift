import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct ReferenceNavigationTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_REFERENCE_SIMULATOR"] != nil))
    func prepareReadOnlyReferenceUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_REFERENCE_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      let client = try #require(model.client)
      let topic = try #require(try await client.rows(table: "topics", search: "Field notes").first)
      _ = try await client.write(
        table: "notes",
        patch: [
          "title": .string("Navigation read-only fixture"), "topic": .string(topic.id),
        ])
      await model.close()
      let runtime = try IrisCoreRuntime()
      let fixture = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      runtime.context.evaluateScript(
        #"""
        IrisSql.run("UPDATE notes SET related='[\"missing-fixture-reference\"]' WHERE title='Navigation read-only fixture'");
        IrisSql.run("UPDATE catalog_tables SET kind='system' WHERE id='notes'");
        """#)
      #expect(runtime.context.exception == nil)
      try await fixture.close()
    }
  #endif

  private let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
  ]
  private let original: WorkspaceRecord = [
    "id": .string("source"), "title": .string("Source"), "body": .string("Body"),
    "updated_at": .string("revision-1"),
  ]
  private let target = WorkspaceRow(
    record: ["id": .string("target"), "title": .string("Target"), "body": .string("Full source")],
    label: "Target")

  private func editor(store: EditorDraftStore? = nil) -> RecordEditorModel {
    RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store,
      debounce: .seconds(60)
    ) { _, _ in
      throw WorkspaceError(message: "Navigation must not write", violations: [])
    }
  }

  @Test func realCoreOpensFreshFullLocalRowFromReadOnlySourceAndSkippedTable() async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let target = try #require(try await client.rows(table: "notes").first)
    runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE catalog_tables SET kind='system' WHERE id='topics'\")")
    #expect(runtime.context.exception == nil)
    let workspace = WorkspaceModel()
    workspace.client = client
    workspace.catalog = try await client.catalog()
    workspace.table = "topics"
    await workspace.reload()
    #expect(!workspace.canWrite)
    let context = try #require(workspace.editingContext)
    let source = editor()
    let navigation = workspace.makeReferenceNavigation(editor: source, context: context)
    workspace.isReplica = true
    workspace.syncStatus = CoreSyncStatus(
      lastSuccessfulSync: nil, pendingUiEdits: 0, rejected: 0, skippedTables: ["notes"])
    #expect(workspace.skippedTables.contains("notes"))
    let updated = try await client.write(
      table: "notes",
      patch: [
        "id": .string(target.id),
        "title": .string("Renamed target"), "body": .string("Fresh unprojected Markdown"),
      ],
      expectedUpdatedAt: target.record["updated_at"]?.text)
    let opened = try #require(await navigation.open(table: "notes", id: target.id))
    #expect(opened.row.record["body"] == .string("Fresh unprojected Markdown"))
    #expect(opened.row.record["updated_at"] == updated["updated_at"])
    #expect(opened.row.label == "Renamed target")
    #expect(workspace.table == "topics", "Resolving must not change the source editor's table")
    #expect(await navigation.open(table: "unreplicated", id: "unknown") == nil)
    #expect(navigation.error?.contains("table") == true)
    workspace.table = "notes"
    workspace.table = "topics"
    #expect(await navigation.open(table: "notes", id: target.id) == nil)
    await workspace.close()
  }

  @Test func cancelAndMissingTargetsRetainDraftsDiscardOnlyRemovesOwnedVariant() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EditorDraftStore(
      root: directory.appendingPathComponent("drafts"),
      workspace: directory.appendingPathComponent("workspace.sqlite"))
    let source = editor(store: store)
    let other = editor(store: store)
    source.setValue("Keep source", for: "title")
    other.setValue("Other window", for: "body")
    var available = true
    var body = "Fresh first read"
    var openedIDs: [String] = []
    let navigation = ReferenceNavigationModel(
      editor: source,
      read: { view in
        #expect(view.table == "topics" && view.columns == nil && view.limit == 1)
        #expect(
          view.search == nil
            && view.filters == [CoreFilter(column: "id", op: .eq, value: .string("target"))])
        return available
          ? [
            WorkspaceRow(
              record: target.record.merging(["body": .string(body)]) { _, new in new },
              label: "Target")
          ] : []
      },
      onOpen: { destination in
        openedIDs.append(destination.row.id)
        #expect((try? store.all().count) == 1, "Only the other window's journal remains at handoff")
      })
    #expect(await navigation.open(table: "topics", id: "target") == nil)
    #expect(navigation.confirmation != nil)
    navigation.cancel()
    #expect(navigation.confirmation == nil)
    #expect(source.draft.values["title"] == "Keep source")
    #expect(openedIDs.isEmpty)
    #expect(try store.all().count == 2)
    _ = await navigation.open(table: "topics", id: "target")
    available = false
    #expect(await navigation.discardAndOpen() == nil)
    #expect(navigation.error?.contains("locally") == true)
    #expect(try store.all().count == 2)
    available = true
    _ = await navigation.open(table: "topics", id: "target")
    body = "Changed while confirming"
    let opened = try #require(await navigation.discardAndOpen())
    #expect(
      opened.table == "topics" && opened.row.record["body"] == .string("Changed while confirming"))
    let retained = try store.all()
    #expect(openedIDs == ["target"])
    #expect(retained.count == 1)
    #expect(retained.first?.draft.values["body"] == "Other window")
    try other.discardDraft()
  }

  @Test(arguments: ["cancel", "context", "newer", "error"])
  func staleReadCannotOpenOrReplaceANewerError(transition: String) async throws {
    let source = editor()
    var current = true
    var held: CheckedContinuation<[WorkspaceRow], any Error>?
    let navigation = ReferenceNavigationModel(
      editor: source,
      read: { view in
        if view.table == "old" { return try await withCheckedThrowingContinuation { held = $0 } }
        return []
      }, isCurrent: { current })
    let pending = Task { await navigation.open(table: "old", id: "target") }
    while held == nil { await Task.yield() }
    if transition == "cancel" {
      navigation.cancel()
    } else if transition == "context" {
      current = false
    } else {
      _ = await navigation.open(table: "new", id: "missing")
    }
    let newerError = navigation.error
    if transition == "error" {
      held?.resume(throwing: WorkspaceError(message: "Obsolete failure", violations: []))
    } else {
      held?.resume(returning: [target])
    }
    #expect(await pending.value == nil)
    #expect(navigation.error == newerError)
    #expect(navigation.confirmation == nil)
    #expect(!navigation.loading, "A stale read must not leave the retained source editor disabled")
  }

  @Test func typingAfterDiscardConfirmationNeverDiscardsUnconfirmedText() async throws {
    let source = editor()
    source.setValue("First edit", for: "title")
    var held: CheckedContinuation<[WorkspaceRow], any Error>?
    var reads = 0
    let navigation = ReferenceNavigationModel(
      editor: source,
      read: { _ in
        reads += 1
        if reads == 2 { return try await withCheckedThrowingContinuation { held = $0 } }
        return [target]
      })
    _ = await navigation.open(table: "topics", id: "target")
    let opening = Task { await navigation.discardAndOpen() }
    while held == nil { await Task.yield() }
    source.setValue("Later edit", for: "title")
    held?.resume(returning: [target])
    #expect(await opening.value == nil)
    #expect(source.draft.values["title"] == "Later edit")
    #expect(navigation.error != nil)
  }

  @Test func cleanNavigationKeepsUnresumedRecoveryAndUnreadableFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EditorDraftStore(
      root: directory.appendingPathComponent("drafts"),
      workspace: directory.appendingPathComponent("workspace.sqlite"))
    let other = editor(store: store)
    other.setValue("Retained recovery", for: "title")
    let saved = try #require(store.all().first)
    let source = editor(store: store)
    #expect(source.recovery != nil && !source.dirty)
    let navigation = ReferenceNavigationModel(editor: source, read: { _ in [target] })
    #expect(await navigation.open(table: "topics", id: "target") != nil)
    #expect(try store.all().map(\.id) == [saved.id])
    let broken = store.directory.appendingPathComponent("unreadable.json")
    let bytes = Data("synthetic damaged journal".utf8)
    try bytes.write(to: broken)
    let unreadable = editor(store: store)
    let blocked = ReferenceNavigationModel(editor: unreadable, read: { _ in [target] })
    #expect(await blocked.open(table: "topics", id: "target") == nil)
    blocked.cancel()
    #expect(try Data(contentsOf: broken) == bytes)
    _ = await blocked.open(table: "topics", id: "target")
    #expect(await blocked.discardAndOpen() != nil)
    #expect(try Data(contentsOf: broken) == bytes)
    try other.discardDraft()
  }

  @Test func navigationWaitsForAnInFlightAutosaveAndAsksOnlyIfItFails() async throws {
    var receipt: CheckedContinuation<WorkspaceRecord, any Error>?
    let source = RecordEditorModel(
      properties: properties, original: original, table: "notes",
      store: nil, debounce: .seconds(60)
    ) { _, _ in
      try await withCheckedThrowingContinuation { receipt = $0 }
    }
    source.setValue("Pending", for: "body")
    let save = Task { try await source.flushAutosave() }
    while receipt == nil { await Task.yield() }
    source.setValue("Body", for: "body")
    var reads = 0
    let navigation = ReferenceNavigationModel(
      editor: source,
      read: { _ in
        #expect(!source.saving, "A reference read started during a pending save")
        reads += 1
        return [target]
      })
    let opening = Task { await navigation.open(table: "topics", id: "target") }
    for _ in 0..<50 { await Task.yield() }
    #expect(reads == 0 && navigation.loading)
    receipt?.resume(throwing: WorkspaceError(message: "Synthetic save failure", violations: []))
    // The failed draft cannot be stored, so leaving asks before it is discarded.
    #expect(await opening.value == nil)
    #expect(navigation.confirmation != nil)
    await #expect(throws: WorkspaceError.self) { try await save.value }
    try source.discardDraft()
  }
}
