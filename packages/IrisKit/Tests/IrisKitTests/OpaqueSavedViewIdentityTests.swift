import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct OpaqueSavedViewIdentityTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["IRIS_TEST_SAVED_VIEW_ID_SIMULATOR"] != nil))
    func prepareOpaqueSavedViewUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["IRIS_TEST_SAVED_VIEW_ID_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let runtime = try IrisCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      runtime.context.evaluateScript(
        #"""
        IrisSql.run("DELETE FROM views WHERE id IN (?,?)", ['\u00e9','e\u0301']);
        """#)
      try #require(runtime.context.exception == nil)
      let a = try await workspace.saveView(
        CoreSaveViewArgs(
          table: "notes", name: "Opaque first view", definition: CoreSavedViewDefinition(version: 1)
        ))
      let b = try await workspace.saveView(
        CoreSaveViewArgs(
          table: "notes", name: "Opaque second view",
          definition: CoreSavedViewDefinition(version: 1)))
      let parameters = String(
        decoding: try JSONEncoder().encode(["\u{00e9}", a.id, "e\u{0301}", b.id]), as: UTF8.self)
      // Imported view IDs are legal opaque TEXT. Only this explicitly owned simulator is modified.
      runtime.context.evaluateScript(
        """
        (() => {
          const p = \(parameters);
          IrisSql.run('UPDATE views SET id=? WHERE id=?', p.slice(0,2));
          IrisSql.run('UPDATE views SET id=? WHERE id=?', p.slice(2,4));
        })();
        """)
      try #require(runtime.context.exception == nil)
      let views = try await workspace.listViews(table: "notes").views
      #expect(views.contains { Data($0.id.utf8) == Data([0xc3, 0xa9]) })
      #expect(views.contains { Data($0.id.utf8) == Data([0x65, 0xcc, 0x81]) })
      try await workspace.close()
    }
  #endif
}
