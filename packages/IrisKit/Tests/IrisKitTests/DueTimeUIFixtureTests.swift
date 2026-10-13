import Foundation
import Testing

@testable import IrisKit

/// Replaces the app's own local workspace on one explicit simulator with a fresh sample
/// for `DueTimeUITests`: a `due` mixed date on notes, a fixture note due today and a
/// "Due today" Now view. Fresh, so rules other fixtures left on this simulator cannot
/// make notes read-only.
@MainActor
struct DueTimeUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["IRIS_TEST_DUE_TIME_SIMULATOR"] != nil))
    func prepareDueTimeUIFixture() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["IRIS_TEST_DUE_TIME_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      let url = try WorkspaceModel.localURL()
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
      await model.open()
      await model.close()
      let workspace = try await NativeWorkspace(path: url.path)
      do {
        _ = try await workspace.saveCatalogProperty(
          CoreSaveCatalogPropertyArgs(
            table: "notes", column: "due", expectedUpdatedAt: nil,
            fields: ["label": .string("Due"), "type": .string("date_or_datetime")],
            addColumn: true))
        _ = try await workspace.write(
          table: "notes",
          patch: [
            "title": .string("Due fixture note"),
            "due": .string(NativeDateValue.currentValue(at: Date(), kind: .date)),
          ])
        _ = try await workspace.saveView(
          CoreSaveViewArgs(
            table: "notes", name: "Due today",
            definition: CoreSavedViewDefinition(
              version: 2, filters: [CoreFilter(column: "due", op: .lte, relative: .now)])))
      } catch {
        _ = try? await workspace.close()
        throw error
      }
      try await workspace.close()
    }
  #endif
}
