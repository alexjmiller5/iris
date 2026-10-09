import CoreSpotlight
import Foundation
import Testing

@testable import IrisKit

/// Seeds the app's own local workspace on an explicitly owned simulator with a
/// synthetic Today view whose 03:00 day start falls soon, for closed-app rollover
/// and widget gallery checks. Never runs on a shared or physical device.
@MainActor struct WidgetRolloverUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_WIDGET_SIMULATOR"] != nil))
    func prepareWidgetRolloverFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_WIDGET_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let zone = try #require(environment["IRIS_TEST_WIDGET_TIME_ZONE"])
      let library = try #require(WidgetLibrary.installed())
      let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
      await model.open()
      do {
        let workspace = try #require(model.client)
        let existing = try await workspace.listViews(table: "notes").views
        // One view per zone, so a later run never inherits an earlier boundary.
        let name = "Synthetic daily " + zone
        var view = existing.first { $0.name == name && $0.deletedAt == nil }
        if view == nil {
          view = try await workspace.saveView(
            CoreSaveViewArgs(
              table: "notes", name: name,
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

    /// After app launches and terminations, the system index still holds the enabled
    /// table's titles as deep-link identities (no refresh here).
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_WIDGET_SIMULATOR"] != nil))
    func spotlightIndexHoldsEnabledTitles() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["IRIS_TEST_WIDGET_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let context = CSSearchQueryContext()
      context.fetchAttributes = ["title"]
      let query = CSSearchQuery(queryString: "title == \"Quick Add fixture saved\"", queryContext: context)
      var found: [CSSearchableItem] = []
      for try await result in query.results { found.append(result.item) }
      #expect(found.count == 1)
      #expect(found.first?.uniqueIdentifier.hasPrefix("iris://open/v1?") == true)
      #expect(found.first?.attributeSet.title == "Quick Add fixture saved")
    }
  #endif
}
