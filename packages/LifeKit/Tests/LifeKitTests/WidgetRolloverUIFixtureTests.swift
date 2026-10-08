import CoreSpotlight
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

    /// The system index holds the enabled table's titles as deep-link identities.
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_WIDGET_SIMULATOR"] != nil))
    func spotlightIndexHoldsEnabledTitles() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(environment["LIFE_UI_TEST_WIDGET_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let context = CSSearchQueryContext()
      context.fetchAttributes = ["title"]
      let query = CSSearchQuery(queryString: "title == \"Quick Add fixture saved\"", queryContext: context)
      var found: [CSSearchableItem] = []
      for try await result in query.results { found.append(result.item) }
      #expect(found.count == 1)
      #expect(found.first?.uniqueIdentifier.hasPrefix("life://open/v1?") == true)
      #expect(found.first?.attributeSet.title == "Quick Add fixture saved")
    }

    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_SPOTLIGHT_PROBE"] != nil))
    func spotlightProbe() async throws {
      func item(_ id: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Probe " + id
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "probe", attributeSet: attributes)
      }
      let named = CSSearchableIndex(name: "LifeUI", protectionClass: .complete)
      let unprotected = CSSearchableIndex(name: "LifeUIProbe")
      try await named.indexSearchableItems([item("named-complete")])
      try await unprotected.indexSearchableItems([item("named-default")])
      try await CSSearchableIndex.default().indexSearchableItems([item("default")])
      try await Task.sleep(for: .seconds(3))
      for text in ["title == \"Probe*\"", "Probe*"] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        var found: [String] = []
        for try await result in CSSearchQuery(queryString: text, queryContext: context).results {
          found.append(result.item.uniqueIdentifier)
        }
        print("PROBE \(text): \(found.sorted())")
      }
      for index in [named, unprotected, CSSearchableIndex.default()] {
        try await index.deleteSearchableItems(withDomainIdentifiers: ["probe"])
      }
    }
  #endif
}
