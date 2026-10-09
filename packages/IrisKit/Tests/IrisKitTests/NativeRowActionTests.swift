import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct NativeRowActionTests {
  @Test(arguments: [false, true])
  func rowActionFailureCannotReplaceANewWorkspaceError(replaceWorkspace: Bool) async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil))
    model.client = workspace
    model.catalog = try await workspace.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let saved = try await workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Action fixture",
        definition: CoreSavedViewDefinition(
          version: 2,
          actions: [
            CoreRowAction(id: "review", label: "Review", values: ["status": .string("Ready")])
          ]
        )))
    try model.applySavedView(saved, context: context)
    await model.reload()
    let row = try #require(model.rows.first)
    try #require(model.canRunRowAction)
    runtime.context.evaluateScript(
      """
      globalThis.originalFinish = __irisFinish;
      globalThis.heldReceipt = null;
      __irisFinish = (id, reply) => { heldReceipt = [id, reply]; };
      """)
    let operation = Task { await model.runRowActionReportingFailure("missing-action", row: row) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while runtime.context.objectForKeyedSubscript("heldReceipt")?.isNull != false {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
    if replaceWorkspace {
      model.client = nil
      model.error = "Replacement workspace error"
    } else {
      model.error = nil
    }
    runtime.context.evaluateScript("__irisFinish = originalFinish; originalFinish(...heldReceipt);")
    await operation.value
    if replaceWorkspace {
      #expect(model.error == "Replacement workspace error")
    } else {
      #expect(model.error?.contains("Saved action is unavailable") == true)
    }
    try await workspace.close()
  }
}
