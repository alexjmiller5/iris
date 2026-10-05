import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct HeaderUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_HEADER_SIMULATOR"] != nil))
    func prepareEmptyWorkspaceHeaderFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_HEADER_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let runtime = try LifeCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      // Only this explicitly selected disposable simulator's synthetic local catalog.
      runtime.context.evaluateScript("LifeSql.run('DELETE FROM catalog_tables')")
      try #require(runtime.context.exception == nil)
      try await workspace.close()
      await model.open()
      #expect(model.client != nil)
      #expect(model.table == nil)
      await model.close()
    }
  #endif
}
