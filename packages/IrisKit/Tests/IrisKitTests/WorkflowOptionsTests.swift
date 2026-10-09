import Testing

@testable import IrisKit

@MainActor
struct WorkflowOptionsTests {
  @Test(arguments: [CoreSortMode.options, .value])
  func extendedSortFromAnOrdinaryViewCanBeSaved(mode: CoreSortMode) async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    try model.applyWorkflowOptions(
      sorts: [CoreSort(column: "status", direction: .asc, mode: mode)], filters: [], groups: [],
      actions: [], layout: nil, timeZone: "UTC", context: context)
    let definition = try model.currentViewDefinition()
    #expect(definition.version == 2)
    let saved = try await context.workspace.saveView(
      CoreSaveViewArgs(table: context.table, name: "Ordered", definition: definition))
    #expect(saved.definition?.sort == definition.sort)
    await model.close()
  }

  @Test func defaultActionLayoutCanBeSavedWithoutSyntheticStorageColumns() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    model.viewActions = [
      CoreRowAction(id: "finish", label: "Finish", values: ["status": .string("Ready")])
    ]
    // This is the same default layout the options form extends with a new action.
    model.viewLayout = model.defaultViewLayout
    let saved = try await context.workspace.saveView(
      CoreSaveViewArgs(
        table: context.table, name: "With action", definition: model.currentViewDefinition()))
    #expect(
      saved.definition?.layout?.contains(CoreViewLayoutItem(kind: "action", id: "finish")) == true)
    #expect(
      saved.definition?.layout?.contains(CoreViewLayoutItem(kind: "column", id: "hub_at")) == false)
    await model.close()
  }
}
