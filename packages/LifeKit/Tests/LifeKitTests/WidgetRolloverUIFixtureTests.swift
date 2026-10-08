import Foundation
import Testing

@testable import LifeKit

/// Seeds the app's own local workspace on an explicitly owned simulator with a
/// synthetic Today view whose 03:00 day start falls soon, for closed-app rollover
/// and widget gallery checks. Never runs on a shared or physical device.
@MainActor struct WidgetRolloverUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_WIDGET_SIMULATOR"] != nil))
    func prepareWidgetRolloverFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_WIDGET_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let zone = try #require(environment["LIFE_UI_TEST_WIDGET_TIME_ZONE"])
      let library = try #require(WidgetLibrary.installed())
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
      await model.open()
      do {
        let workspace = try #require(model.client)
        let existing = try await workspace.listViews(table: "notes").views
        var view = existing.first { $0.name == "Synthetic daily" && $0.deletedAt == nil }
        if view == nil {
          view = try await workspace.saveView(
            CoreSaveViewArgs(
              table: "notes", name: "Synthetic daily",
              definition: CoreSavedViewDefinition(
                version: 2, columns: ["title"],
                filters: [CoreFilter(column: "updated_at", op: .eq, relative: .today)],
                timeZone: zone, dayStartMinutes: 180)))
        }
        let viewID = try #require(view?.id)
        try model.prepareWidgets()
        let widgets = try #require(model.widgets)
        let selections = [
          NativeWidgetSelection(table: "notes", viewID: nil),
          NativeWidgetSelection(table: "notes", viewID: viewID),
        ]
        try #require(await widgets.setSelections(selections, partial: false))
        let integrations = try #require(model.integrations)
        try #require(integrations.setDailySource(selections[1]))
        try #require(integrations.setLookupTable("notes"))
        try #require(await integrations.setSpotlightTables(["notes"]))
        let daily = try #require(widgets.presentation(selections[1], now: Date()))
        #expect(!daily.0.rows.isEmpty)
        #expect(daily.nextBoundary != nil)
      } catch {
        await model.close()
        throw error
      }
      await model.close()
    }
  #endif
}
