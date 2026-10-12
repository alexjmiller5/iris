import XCTest

@MainActor
final class SidebarRecentsUITests: XCTestCase {
  /// Recents keep a display snapshot, so a cold launch paints their titles with the
  /// sidebar: no raw IDs and no loading indicator.
  func testColdLaunchShowsStoredRecentTitlesWithTheSidebar() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["IRIS_TEST_RECENTS_SIMULATOR"] == nil,
      "Writes the local workspace; run only on an explicitly selected disposable simulator.")
    guard environment["IRIS_TEST_RECENTS_SIMULATOR"] == environment["SIMULATOR_UDID"] else {
      throw NSError(
        domain: "SidebarRecentsUITests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Disposable simulator mismatch"])
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    openLocal(app)
    showSidebar(app)
    tap(app.buttons["sidebar-table-topics"])
    XCTAssertTrue(app.navigationBars["topics"].waitForExistence(timeout: 10))
    let record = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", Open record"))
      .firstMatch
    tap(record)
    let title = String(record.label.dropLast(", Open record".count))
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))
    tap(app.navigationBars["Record"].buttons["done-record"])
    showSidebar(app)
    let recents = app.buttons.matching(identifier: "open-recent")
    wait { recents.firstMatch.exists && recents.firstMatch.label.hasPrefix(title) }
    let labels = recents.allElementsBoundByIndex.map(\.label)
    XCTAssertGreaterThan(labels.count, 1)

    app.terminate()
    app.launch()
    openLocal(app)
    showSidebar(app)
    // The first sidebar frame already holds every stored title.
    XCTAssertEqual(recents.allElementsBoundByIndex.map(\.label), labels)
    XCTAssertFalse(app.activityIndicators["Loading recent"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "native-recents-cold-launch"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func openLocal(_ app: XCUIApplication) {
    tap(app.buttons["open-local"])
    let find = app.buttons["quick-find"]
    XCTAssertTrue(find.waitForExistence(timeout: 15))
  }

  private func showSidebar(_ app: XCUIApplication) {
    if app.buttons["quick-find-sidebar"].isHittable { return }
    tap(app.navigationBars.buttons["BackButton"].firstMatch)
    XCTAssertTrue(app.buttons["quick-find-sidebar"].waitForExistence(timeout: 5))
  }

  private func tap(_ element: XCUIElement) {
    wait { element.exists && element.isHittable && element.isEnabled }
    element.tap()
  }

  private func wait(
    file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool
  ) {
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, file: file, line: line)
  }
}
