import Foundation
import Testing

@testable import IrisKit

/// Seeds the app's own local workspace on one explicit simulator for `DueTimeUITests`:
/// a `due` mixed date on notes, a fixture note due today and a "Due today" view. The
/// hosted run also proves the system notification center keeps a scheduled due alert.
@MainActor
struct DueTimeUIFixtureTests {
  #if targetEnvironment(simulator)
    private static var enabled: Bool {
      ProcessInfo.processInfo.environment["IRIS_TEST_DUE_TIME_SIMULATOR"] != nil
    }

    @Test(.enabled(if: enabled)) func prepareDueTimeUIFixture() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["IRIS_TEST_DUE_TIME_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      await model.close()
      let workspace = try await NativeWorkspace(path: WorkspaceModel.localURL().path)
      do {
        let catalog = try await workspace.catalog()
        if !catalog.properties.contains(where: { $0["id"]?.text == "notes.due" }) {
          _ = try await workspace.saveCatalogProperty(
            CoreSaveCatalogPropertyArgs(
              table: "notes", column: "due", expectedUpdatedAt: nil,
              fields: ["label": .string("Due"), "type": .string("date_or_datetime")],
              addColumn: true))
        }
        let today = NativeDateValue.currentValue(at: Date(), kind: .date)
        _ = try await workspace.write(
          table: "notes",
          patch: ["title": .string("Due fixture note"), "due": .string(today)])
        if !(try await workspace.listViews(table: "notes")).views.contains(where: {
          $0.name == "Due today"
        }) {
          _ = try await workspace.saveView(
            CoreSaveViewArgs(
              table: "notes", name: "Due today",
              definition: CoreSavedViewDefinition(
                version: 2, filters: [CoreFilter(column: "due", op: .lte, relative: .now)])))
        }
      } catch {
        try? await workspace.close()
        throw error
      }
      try await workspace.close()
    }

    @Test(.enabled(if: enabled)) func systemCenterKeepsAScheduledDueAlert() async throws {
      let center = SystemDueAlertCenter()
      let request = DueAlertRequest(
        identifier: "iris.due.fixture." + UUID().uuidString, title: "Fixture alert",
        body: "Due", link: try #require(URL(string: "iris://open/v1?fixture")),
        at: Date().addingTimeInterval(3600), floating: true)
      try await center.add(request)
      #expect(await center.pendingIdentifiers().contains(request.identifier))
      center.remove([request.identifier])
      for _ in 0..<50 where await center.pendingIdentifiers().contains(request.identifier) {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(!(await center.pendingIdentifiers().contains(request.identifier)))
    }
  #endif
}
