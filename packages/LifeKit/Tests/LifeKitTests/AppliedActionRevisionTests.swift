import Testing

@testable import LifeKit

@MainActor
struct AppliedActionRevisionTests {
  @Test func refreshedViewListCannotAuthorizeADifferentActionThanDisplayed() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let row = try await context.workspace.write(
      table: "notes", patch: ["title": .string("Revision fixture"), "status": .string("Draft")])
    let definition = CoreSavedViewDefinition(
      version: 2,
      actions: [
        CoreRowAction(id: "finish", label: "Finish", values: ["status": .string("Ready")])
      ])
    let displayed = try await context.workspace.saveView(
      CoreSaveViewArgs(table: "notes", name: "Action fixture", definition: definition))
    try model.applySavedView(displayed, context: context)
    await model.reload()
    let target = try #require(model.rows.first { $0.id == row["id"]?.text })
    var changed = definition
    changed.actions = [
      CoreRowAction(id: "finish", label: "Finish", values: ["title": .string("Changed action")])
    ]
    let latest = try await context.workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Action fixture", definition: changed,
        id: displayed.id, expectedUpdatedAt: displayed.updatedAt))
    try await model.refreshSavedViews(context: context)
    #expect(model.savedViews.first?.updatedAt == latest.updatedAt)
    let previousUndo = model.undoAction
    await #expect(throws: (any Error).self) {
      try await model.runRowAction("finish", row: target, context: context)
    }
    #expect(model.appliedView?.updatedAt == displayed.updatedAt)
    #expect(model.undoAction == previousUndo)
    try model.applySavedView(latest, context: context)
    await model.reload()
    try await model.runRowAction("finish", row: target, context: context)
    #expect(model.undoAction != nil)
    await model.close()
  }
}
