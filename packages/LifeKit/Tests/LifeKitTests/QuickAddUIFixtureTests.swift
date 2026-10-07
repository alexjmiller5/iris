import Foundation
import LifeWidgets
import Testing

@testable import LifeKit

@MainActor struct QuickAddUIFixtureTests {
  #if targetEnvironment(simulator)
    private func requireOwnedSimulator() throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_QUICK_ADD_SIMULATOR"] != nil)
      try #require(environment["LIFE_UI_TEST_QUICK_ADD_SIMULATOR"] == environment["SIMULATOR_UDID"])
    }

    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_QUICK_ADD_SIMULATOR"] != nil))
    func prepareQuickAddUIFixture() async throws {
      try requireOwnedSimulator()
      let library = try #require(WidgetLibrary.installed())
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
      await model.open()
      do {
        try model.prepareWidgets()
        try #require(
          await model.widgets!.setSelections(
            [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
        let source = try #require(
          try await QuickAddSourceQuery(library: library).suggestedEntities().first)
        let before = try await model.client!.rows(table: "notes")
        let receipt = try WorkspaceModel.localURL().appendingPathExtension("quick-add-fixture.json")
        try JSONEncoder().encode(before.count).write(to: receipt, options: .atomic)
        var intent = QuickAddIntent(source: source)
        intent.text = "# Synthetic Quick Add\n\nExact retained body."
        intent.column = "body"
        _ = try await intent.perform()
        // Same invocation replay keeps the request identity and creates no row.
        _ = try await intent.perform()
        #expect(try model.pendingQuickAdd() != nil)
        #expect(try await model.client!.rows(table: "notes").count == before.count)
      } catch {
        await model.close()
        throw error
      }
      await model.close()
    }

    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_QUICK_ADD_SIMULATOR"] != nil))
    func verifyQuickAddUIReadback() async throws {
      try requireOwnedSimulator()
      let file = try WorkspaceModel.localURL()
      let receipt = file.appendingPathExtension("quick-add-fixture.json")
      let before = try JSONDecoder().decode(Int.self, from: Data(contentsOf: receipt))
      let workspace = try NativeWorkspace(path: file.path)
      do {
        let rows = try await workspace.rows(table: "notes")
        #expect(rows.count == before + 1)
        let captured = rows.filter { $0.record["title"] == .string("Quick Add fixture saved") }
        #expect(captured.count == 1)
        #expect(
          captured.first?.record["body"] == .string("# Synthetic Quick Add\n\nExact retained body.")
        )
        try FileManager.default.removeItem(at: receipt)
      } catch {
        try? await workspace.close()
        throw error
      }
      try await workspace.close()
    }
  #endif
}
