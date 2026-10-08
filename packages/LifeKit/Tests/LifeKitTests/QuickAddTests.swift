import Foundation
import LifeExtensionSupport
import LifeWidgets
import Testing

@testable import LifeKit

@MainActor struct QuickAddTests {
  private func fixture(
    _ body: (NativeWorkspace, WidgetLibrary, WidgetPublicationStore, String) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library, workspaceID: "workspace", replicaID: "replica",
      preferencesURL: root.appendingPathComponent("widgets.json"), binding: .local(UUID()))
    try #require(
      await settings.setSelections(
        [
          NativeWidgetSelection(table: "notes", viewID: nil)
        ], partial: false))
    let source = try #require(try library.sources().first { $0.kind == .list })
    do {
      try await body(workspace, library, library.store(workspaceID: "workspace"), source.id)
    } catch {
      try? await workspace.close()
      throw error
    }
    try await workspace.close()
  }

  @Test func pendingRequestSurvivesRelaunchAndRefusesReplacement() async throws {
    try await fixture { workspace, _, store, sourceID in
      let rows = try await workspace.rows(table: "notes")
      let id = UUID()
      let raw = " # Exact\n café and cafe\u{301} "
      let request = try #require(try store.stageQuickAdd(id: id, sourceID: sourceID, text: raw, column: "body"))
      let reopened = WidgetPublicationStore(root: store.root)
      #expect(try reopened.pendingQuickAdd()?.id == id)
      #expect(Data(try reopened.pendingQuickAdd()!.text!.utf8) == Data(raw.utf8))
      #expect(
        try reopened.stageQuickAdd(id: id, sourceID: sourceID, text: raw, column: "body")?.id == id)
      #expect(throws: (any Error).self) {
        try reopened.stageQuickAdd(id: UUID(), sourceID: sourceID, text: "Replace", column: "body")
      }
      #expect(try await workspace.rows(table: "notes").map(\.record) == rows.map(\.record))
      #expect(throws: (any Error).self) { try reopened.finishQuickAdd(id: UUID()) }
      #expect(try reopened.pendingQuickAdd()?.id == request.id)
      try reopened.finishQuickAdd(id: id)
      #expect(try reopened.pendingQuickAdd() == nil)
    }
  }

  @Test func consumedRequestsReplayAsDeliveredAfterRelaunch() async throws {
    try await fixture { workspace, _, store, sourceID in
      let rows = try await workspace.rows(table: "notes")
      let finished = UUID()
      _ = try store.stageQuickAdd(id: finished, sourceID: sourceID, text: nil, column: nil)
      try store.finishQuickAdd(id: finished)
      let discarded = UUID()
      _ = try store.stageQuickAdd(id: discarded, sourceID: sourceID, text: "x", column: "body")
      try store.discardQuickAdd(id: discarded)
      let reopened = WidgetPublicationStore(root: store.root)
      for id in [finished, discarded] {
        #expect(try reopened.stageQuickAdd(id: id, sourceID: sourceID, text: nil, column: nil) == nil)
        #expect(try reopened.pendingQuickAdd() == nil)
      }
      let next = UUID()
      #expect(try reopened.stageQuickAdd(id: next, sourceID: sourceID, text: nil, column: nil)?.id == next)
      #expect(try await workspace.rows(table: "notes").count == rows.count)
    }
  }

  @Test func invalidAndRevokedInputsNeverReplaceDurableRequest() async throws {
    try await fixture { _, library, store, sourceID in
      #expect(try library.sources().first { $0.id == sourceID }?.allowsQuickAdd == true)
      #expect(
        try await QuickAddSourceQuery(library: library).suggestedEntities().map(\.id) == [sourceID])
      #expect(try await QuickAddSourceQuery(library: library).entities(for: ["unknown"]).isEmpty)
      for input: (String?, String?) in [
        ("text", nil), (nil, "body"), (String(repeating: "é", count: 32769), "body"),
      ] {
        #expect(throws: (any Error).self) {
          try store.stageQuickAdd(id: UUID(), sourceID: sourceID, text: input.0, column: input.1)
        }
      }
      #expect(throws: (any Error).self) {
        try store.stageQuickAdd(id: UUID(), sourceID: "unknown", text: nil, column: nil)
      }
      let request = try #require(try store.stageQuickAdd(id: UUID(), sourceID: sourceID, text: nil, column: nil))
      try store.revoke()
      #expect(throws: (any Error).self) { try store.pendingQuickAdd() }
      #expect(
        FileManager.default.fileExists(
          atPath: store.root.appendingPathComponent("quick-add.json").path))
      #expect(throws: (any Error).self) { try store.finishQuickAdd(id: request.id) }
      #expect(try store.retainedQuickAdd()?.id == request.id)
      #expect(throws: (any Error).self) { try store.discardQuickAdd(id: UUID()) }
      try store.discardQuickAdd(id: request.id)
      #expect(try store.retainedQuickAdd() == nil)
    }
  }

  @Test func corruptRequestIsKeptAndNeverTreatedAsAbsent() async throws {
    try await fixture { _, _, store, sourceID in
      let path = store.root.appendingPathComponent("quick-add.json")
      try Data("null".utf8).write(to: path)
      #expect(throws: (any Error).self) { try store.pendingQuickAdd() }
      #expect(throws: (any Error).self) {
        try store.stageQuickAdd(id: UUID(), sourceID: sourceID, text: nil, column: nil)
      }
      #expect(try Data(contentsOf: path) == Data("null".utf8))
    }
  }

  @Test func maximumEscapedTextSurvivesItsJSONHandoff() async throws {
    try await fixture { _, _, store, sourceID in
      let text = String(repeating: "\n", count: 65536)
      let request = try #require(
        try store.stageQuickAdd(id: UUID(), sourceID: sourceID, text: text, column: "body"))
      #expect(try store.pendingQuickAdd()?.text == text)
      try store.finishQuickAdd(id: request.id)
    }
  }

  @Test func readOnlyAndCountPublicationsCannotPrepareQuickAdd() async throws {
    try await fixture { _, library, store, sourceID in
      let count = try #require(try library.sources().first { $0.kind == .count })
      #expect(throws: (any Error).self) {
        try store.stageQuickAdd(id: UUID(), sourceID: count.id, text: nil, column: nil)
      }
      let publication = try store.withCurrentPublication { ($0, $1) }
      let sources = publication.0.sources.map {
        WidgetSource(
          id: $0.id, title: $0.title, plan: $0.plan, openURL: $0.openURL, allowsQuickAdd: false)
      }
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: sources
      ) {
        try FileManager.default.copyItem(at: publication.1, to: $0)
      }
      #expect(try await QuickAddSourceQuery(library: library).suggestedEntities().isEmpty)
      #expect(throws: (any Error).self) {
        try store.stageQuickAdd(id: UUID(), sourceID: sourceID, text: nil, column: nil)
      }
    }
  }

  @Test func hostCreatesOneRecoverableDraftAndNoRowUntilSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
    await model.open()
    do {
      try model.prepareWidgets()
      let settings = try #require(model.widgets)
      try #require(
        await settings.setSelections(
          [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
      let source = try #require(try library.sources().first { $0.kind == .list })
      let store = library.store(workspaceID: source.workspaceID)
      let request = try #require(
        try store.stageQuickAdd(id: UUID(), sourceID: source.id, text: " # Captured\n", column: "body"))
      let workspace = try #require(model.client)
      let before = try await workspace.rows(table: "notes")
      let editor = try await model.prepareQuickAdd(request)
      #expect(editor.draft.values["body"] == " # Captured\n")
      #expect(try store.pendingQuickAdd() == nil)
      #expect(try await workspace.rows(table: "notes").count == before.count)
      editor.setValue("Synthetic Quick Add", for: "title")
      try await editor.saveAll()
      #expect(try await workspace.rows(table: "notes").count == before.count + 1)
      #expect(throws: WorkspaceError.self) { try model.quickAddDestination(request) }
    } catch {
      await model.close()
      throw error
    }
    await model.close()
  }

  @Test func hostRefusesUnavailableFieldWithoutRemovingPendingInput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
    await model.open()
    do {
      try model.prepareWidgets()
      try #require(
        await model.widgets!.setSelections(
          [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
      let source = try #require(try library.sources().first { $0.kind == .list })
      let store = library.store(workspaceID: source.workspaceID)
      let request = try #require(
        try store.stageQuickAdd(id: UUID(), sourceID: source.id, text: "Keep this input", column: "missing"))
      await #expect(throws: WorkspaceError.self) { try await model.prepareQuickAdd(request) }
      #expect(try store.pendingQuickAdd()?.id == request.id)
      #expect(try model.editingContext?.draftStore?.all().isEmpty == true)
    } catch {
      await model.close()
      throw error
    }
    await model.close()
  }
}
