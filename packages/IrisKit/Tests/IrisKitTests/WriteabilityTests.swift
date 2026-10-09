import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct WriteabilityTests {
  @Test func oldAdvisoryCannotEnableEditingAfterTableOrWorkspaceChanges() async throws {
    for transition in ["table", "tableRoundTrip", "workspace"] {
      let runtime = try IrisCoreRuntime()
      let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
      try await client.createSample()
      let model = WorkspaceModel()
      model.client = client
      model.catalog = try await client.catalog()
      model.table = "notes"
      await model.reload()
      #expect(model.canWrite)
      runtime.context.evaluateScript(
        """
        globalThis.originalFinish = __irisFinish;
        globalThis.heldReceipt = null;
        __irisFinish = (id, reply) => { heldReceipt = [id, reply]; };
        """)
      let checking = Task { await model.refreshWriteability() }
      while runtime.context.objectForKeyedSubscript("heldReceipt")?.isNull != false {
        await Task.yield()
      }
      if transition == "workspace" {
        model.client = nil
      } else {
        model.table = "history"
        if transition == "tableRoundTrip" { model.table = "notes" }
      }
      #expect(!model.canWrite)
      runtime.context.evaluateScript(
        "__irisFinish = originalFinish; originalFinish(...heldReceipt);")
      await checking.value
      #expect(!model.canWrite)
      #expect(model.writeability == nil)
      try await client.close()
    }
  }
}
