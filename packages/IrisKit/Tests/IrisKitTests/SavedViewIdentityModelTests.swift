import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct SavedViewIdentityModelTests {
  private let first = Data([0xc3, 0xa9])
  private let second = Data([0x65, 0xcc, 0x81])

  private func workspace() async throws -> WorkspaceModel {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let definition = CoreSavedViewDefinition(
      version: 1, columns: ["title"], sort: [CoreSort(column: "title", direction: .desc)],
      search: "fixture", widths: ["title": 240])
    let a = try await client.saveView(
      CoreSaveViewArgs(table: "notes", name: "First", definition: definition))
    let b = try await client.saveView(
      CoreSaveViewArgs(table: "notes", name: "Second", definition: definition))
    let params = String(
      decoding: try JSONEncoder().encode(["\u{00e9}", a.id, "e\u{0301}", b.id]), as: UTF8.self)
    runtime.context.evaluateScript(
      """
      (() => {
        const p = \(params);
        IrisSql.run('UPDATE views SET id=? WHERE id=?', p.slice(0,2));
        IrisSql.run('UPDATE views SET id=? WHERE id=?', p.slice(2,4));
      })();
      """)
    try #require(runtime.context.exception == nil)
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    await model.reload()
    try await model.refreshSavedViews(context: model.editingContext)
    #expect(Set(model.savedViews.map { Data($0.id.utf8) }) == [first, second])
    return model
  }

  @Test(arguments: [false, true])
  func updatingOneViewPreservesItsByteDistinctSibling(reverse: Bool) async throws {
    let model = try await workspace()
    let context = try #require(model.editingContext)
    let selectedID = reverse ? second : first
    let otherID = reverse ? first : second
    let selected = try #require(model.savedViews.first { Data($0.id.utf8) == selectedID })
    let other = try #require(model.savedViews.first { Data($0.id.utf8) == otherID })
    try model.applySavedView(selected, context: context)
    try await model.saveCurrentView(name: "Updated chosen view", update: true, context: context)
    #expect(Set(model.savedViews.map { Data($0.id.utf8) }) == [first, second])
    #expect(model.savedViews.first { Data($0.id.utf8) == otherID }?.name == other.name)
    #expect(model.appliedView.map { Data($0.id.utf8) } == selectedID)
    let stored = try await context.workspace.listViews(table: "notes").views
    #expect(stored.first { Data($0.id.utf8) == selectedID }?.name == "Updated chosen view")
    #expect(stored.first { Data($0.id.utf8) == otherID }?.name == other.name)
    await model.close()
  }

  @Test(arguments: [false, true])
  func deletingOtherViewKeepsAppliedSettingsAndExactStoredRow(reverse: Bool) async throws {
    let model = try await workspace()
    let context = try #require(model.editingContext)
    let selectedID = reverse ? second : first
    let otherID = reverse ? first : second
    let selected = try #require(model.savedViews.first { Data($0.id.utf8) == selectedID })
    let other = try #require(model.savedViews.first { Data($0.id.utf8) == otherID })
    try model.applySavedView(selected, context: context)
    let definition = try model.currentViewDefinition()
    try await model.deleteSavedView(other, context: context)
    #expect(model.savedViews.map { Data($0.id.utf8) } == [selectedID])
    #expect(model.appliedView.map { Data($0.id.utf8) } == selectedID)
    #expect(model.appliedView?.updatedAt == selected.updatedAt)
    #expect(try model.currentViewDefinition() == definition)
    let stored = try await context.workspace.listViews(table: "notes").views
    #expect(stored.map { Data($0.id.utf8) } == [selectedID])
    let trashed = try await context.workspace.rows(table: "views", trash: true)
    #expect(trashed.map { Data($0.id.utf8) } == [otherID])
    await model.close()
  }

  @Test func deletingAppliedViewClearsOnlyItsSelectionAndKeepsSibling() async throws {
    let model = try await workspace()
    let context = try #require(model.editingContext)
    let selected = try #require(model.savedViews.first { Data($0.id.utf8) == first })
    try model.applySavedView(selected, context: context)
    try await model.deleteSavedView(selected, context: context)
    #expect(model.appliedView == nil && model.search.isEmpty && model.sortRules.isEmpty)
    #expect(model.savedViews.map { Data($0.id.utf8) } == [second])
    #expect(
      try await context.workspace.listViews(table: "notes").views.map { Data($0.id.utf8) } == [
        second
      ])
    await model.close()
  }
}
