import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct HeaderUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_HEADER_SIMULATOR"] != nil))
    func prepareEmptyWorkspaceHeaderFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_HEADER_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let runtime = try IrisCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      // Only this explicitly selected disposable simulator's synthetic local catalog.
      runtime.context.evaluateScript("IrisSql.run('DELETE FROM catalog_tables')")
      try #require(runtime.context.exception == nil)
      try await workspace.close()
      await model.open()
      #expect(model.client != nil)
      #expect(model.table == nil)
      await model.close()
    }
  #endif
}
