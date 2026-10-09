import Foundation
import Testing

@testable import LifeKit

@MainActor
struct FilterBarTests {
  private func notes(_ model: WorkspaceModel) async throws -> WorkspaceEditingContext {
    let context = try #require(model.editingContext)
    for (title, status) in [("Filterbar Draft", "Draft"), ("Filterbar Ready", "Ready")] {
      _ = try await context.workspace.write(
        table: "notes", patch: ["title": .string(title), "status": .string(status)])
    }
    await model.reload()
    return context
  }

  @Test func firstOpenInstallsTheCatalogDefaultSavedView() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let applied = try #require(model.appliedView)
    #expect(applied.name == "Default view")
    #expect(applied.definition == CoreSavedViewDefinition(version: 1))
    #expect(!model.viewModified)
    let again = try await #require(model.client).ensureDefaultView(table: "notes")
    #expect(again.view?.byteExactID == applied.byteExactID)
    await model.close()
  }

  @Test func chipsApplyImmediatelyAndIncompleteChipsNeitherFilterNorSave() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    _ = try await notes(model)
    #expect(model.rows.count == 3)
    let id = model.addFilter(column: "status")
    #expect(model.filters.map(\.id) == [id])
    #expect(model.filters[0].operation == .eq)
    await model.reload()
    #expect(model.rows.count == 3)
    #expect(try model.currentViewDefinition().filters == nil)
    #expect(!model.viewModified)
    let before = model.queryKey
    model.filters[0].value = "Draft"
    #expect(model.queryKey != before)
    await model.reload()
    #expect(model.rows.map(\.label).contains("Filterbar Draft"))
    #expect(!model.rows.map(\.label).contains("Filterbar Ready"))
    #expect(model.rows.count == 2)
    #expect(model.viewModified)
    let group = model.addFilterGroup(column: "status")
    #expect(try model.currentViewDefinition().groups == nil)
    model.filterGroups[0].filters[0].value = "Ready"
    #expect(try model.currentViewDefinition().groups?.first?.filters.count == 1)
    model.removeFilterGroup(group)
    model.removeFilter(id)
    await model.reload()
    #expect(model.rows.count == 3)
    #expect(!model.viewModified)
    await model.close()
  }

  @Test func dismissalSavesOnceAfterTheDebounceThroughTheRevisionCheckedWriterWithUndo()
    async throws
  {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try await notes(model)
    let opened = try #require(model.appliedView)
    let id = model.addFilter(column: "status")
    model.filters[0].value = "Ready"
    model.scheduleViewSave(after: .milliseconds(300))
    model.setSort(column: "title", ascending: false)
    model.scheduleViewSave(after: .milliseconds(300))
    #expect(model.hasPendingViewSave)
    #expect(model.appliedView?.updatedAt == opened.updatedAt)
    await model.flushViewSave()
    #expect(!model.hasPendingViewSave)
    #expect(model.viewSaveError == nil)
    let saved = try #require(model.appliedView)
    #expect(saved.byteExactID == opened.byteExactID)
    #expect(saved.updatedAt != opened.updatedAt)
    #expect(saved.definition?.filters == [CoreFilter(column: "status", op: .eq, value: .string("Ready"))])
    #expect(saved.definition?.sort == [CoreSort(column: "title", direction: .desc)])
    #expect(!model.viewModified)
    let stored = try await context.workspace.listViews(table: "notes").views.first {
      $0.byteExactID == opened.byteExactID
    }
    #expect(stored?.definition == saved.definition)
    let action = try #require(model.undoAction)
    #expect(action.table == "views")
    try await model.undo(action, context: context)
    #expect(model.filters.isEmpty)
    #expect(model.sortRules.isEmpty)
    #expect(model.appliedView?.definition?.filters == nil)
    _ = id
    await model.close()
  }

  @Test func savedFiltersSurviveRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "filterbar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.sqlite")
    let first = WorkspaceModel(localURL: { file })
    await first.open()
    _ = try await notes(first)
    _ = first.addFilter(column: "status")
    first.filters[0].value = "Draft"
    first.scheduleViewSave(after: .seconds(30))
    await first.close()
    let second = WorkspaceModel(localURL: { file })
    await second.open()
    #expect(second.appliedView?.name == "Default view")
    #expect(second.filters.map(\.value) == ["Draft"])
    await second.close()
  }

  @Test func searchAndTrashAreBrowsingStateAndUndoFlushesThePendingSave() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try await notes(model)
    let opened = try #require(model.appliedView)
    model.search = "filterbar"
    model.scheduleViewSave(after: .milliseconds(10))
    #expect(!model.hasPendingViewSave)
    _ = model.addFilter(column: "status")
    model.filters[0].value = "Ready"
    model.scheduleViewSave(after: .seconds(30))
    await model.flushViewSave()
    let saved = try #require(model.appliedView)
    #expect(saved.definition?.filters?.count == 1)
    #expect(saved.definition?.search == nil)
    #expect(saved.definition?.trash == nil)
    model.search = ""
    model.setSort(column: "title", ascending: true)
    model.scheduleViewSave(after: .seconds(30))
    #expect(model.hasPendingViewSave)
    // Undo first saves the pending edit, then reverts exactly that latest change.
    try await model.undoLatest(context: context)
    #expect(!model.hasPendingViewSave)
    #expect(model.sortRules.isEmpty)
    #expect(model.filters.map(\.value) == ["Ready"])
    #expect(model.appliedView?.byteExactID == opened.byteExactID)
    await model.close()
  }

  @Test func navigationSettlesAnInFlightViewSaveInsteadOfRefusing() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let client = try #require(model.client)
    _ = model.addFilter(column: "status")
    model.filters[0].value = "Draft"
    model.scheduleViewSave(after: .zero)
    let inFlight = Task { await model.flushViewSave() }
    while !model.savingView { await Task.yield() }
    #expect(throws: WorkspaceError.self) {
      try model.requireNavigationReady(workspace: client, generation: model.workspaceGeneration)
    }
    await model.flushViewSave()
    try model.requireNavigationReady(workspace: client, generation: model.workspaceGeneration)
    #expect(model.appliedView?.definition?.filters?.count == 1)
    await inFlight.value
    await model.close()
  }

  @Test func passiveNoticeSkipsTheTransientWriteabilityCheck() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    model.table = "history"
    #expect(model.editingUnavailable == "Checking editing availability…")
    #expect(model.editingRefusal == nil)
    await model.refreshWriteability()
    #expect(model.editingRefusal != nil)
    #expect(model.editingRefusal == model.editingUnavailable)
    await model.close()
  }
}

