import UIKit
import XCTest

@MainActor
final class NavigationUITests: XCTestCase {
  func testPaletteKeyboardPagingFreshRecordAndHistory() throws {
    let app = try openLocal()
    defer { app.terminate() }
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["quick-find-table-notes"].waitForExistence(timeout: 5))
    setQuery("notes", in: app)
    let table = app.buttons["quick-find-table-notes"]
    wait { table.isSelected }
    query.typeKey(.downArrow, modifierFlags: [])
    wait { !table.isSelected }
    query.typeKey(.upArrow, modifierFlags: [])
    wait { table.isSelected }
    tap(app.keyboards.buttons["Go"])
    XCTAssertTrue(query.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["notes"].exists)

    tap(app.buttons["quick-find"])
    setQuery("Navigation", in: app)
    let unavailable = app.buttons["quick-find-view-notes-nav-broken"]
    XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
    XCTAssertFalse(unavailable.isEnabled)
    XCTAssertTrue(unavailable.label.contains("Unsupported saved-view definition version."))
    wait { app.buttons["quick-find-view-notes-nav-view"].isSelected }
    tap(app.keyboards.buttons["Go"])
    XCTAssertTrue(query.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Navigation focus"].exists)

    tap(app.buttons["quick-find"])
    setQuery("navflora", in: app)
    XCTAssertTrue(app.staticTexts["50 results"].waitForExistence(timeout: 10))
    tap(app.buttons["quick-find-more"])
    wait {
      let text = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " results"))
        .firstMatch.label
      return (Int(text.split(separator: " ").first ?? "") ?? 0) > 50
    }
    setQuery("navflora note 51", in: app)
    tap(app.buttons["quick-find-result-notes-nav-note-51"])
    let title = app.textFields["field-title"]
    expect(title, value: "Navflora note 51")
    XCTAssertFalse(app.buttons["quick-find"].exists && app.buttons["quick-find"].isEnabled)
    XCTAssertFalse(query.exists, "An open record must retain ownership of its draft")
    tap(title)
    title.typeText(" revised")
    let draft = try XCTUnwrap(title.value as? String)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    let confirmation = app.sheets["Discard unsaved changes?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    // iOS presents this confirmation as a popover; tapping outside cancels it.
    let titlePoint = CGPoint(x: title.frame.midX, y: title.frame.midY)
    XCTAssertFalse(confirmation.frame.contains(titlePoint))
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    expect(title, value: draft)
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 5))
    tap(app.buttons["quick-find"])
    setQuery(draft, in: app)
    tap(app.buttons["quick-find-result-notes-nav-note-51"])
    expect(title, value: draft)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    showSidebar(app)
    // The shared displayName contract trims labels; stored editor values stay exact.
    let displayLabel = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    wait { self.recentLabels(app).first?.contains(displayLabel) == true }
    let visits = recentLabels(app)
    XCTAssertTrue(visits.first?.contains(displayLabel) == true)
    XCTAssertEqual(visits.filter { $0.contains(displayLabel) }.count, 1)
    XCTAssertTrue(visits.contains { $0.contains("Navigation focus") })
    capture(app, "native-navigation-recents")
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    showSidebar(app)
    wait { self.recentLabels(app) == visits }
  }

  func testSystemTablesUnavailableRecentsTrashAndSampleIsolation() throws {
    let app = try openLocal()
    defer { app.terminate() }
    showSidebar(app)
    let missing = app.buttons.matching(identifier: "open-recent").matching(
      NSPredicate(format: "label CONTAINS %@", "nav-missing")
    ).firstMatch
    reveal(missing, in: app)
    XCTAssertFalse(missing.isEnabled)
    let remove = app.buttons.matching(identifier: "remove-recent").matching(
      NSPredicate(format: "label CONTAINS %@", "nav-missing")
    ).firstMatch
    tap(remove)
    XCTAssertTrue(missing.waitForNonExistence(timeout: 5))
    let trash = app.buttons.matching(identifier: "open-recent").matching(
      NSPredicate(format: "label CONTAINS %@", "Navigation discarded")
    ).firstMatch
    reveal(trash, in: app)
    tap(trash)
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["save-record"].exists)
    tap(app.buttons["Restore record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 5))
    showSidebar(app)
    reveal(trash, in: app)
    tap(trash)
    XCTAssertTrue(app.buttons["save-record"].waitForExistence(timeout: 5))
    tap(app.navigationBars["Record"].buttons["Cancel"])
    showSidebar(app)
    let system = app.buttons["System tables"]
    reveal(system, in: app)
    tap(system)
    let history = app.buttons["sidebar-table-history"]
    reveal(history, in: app)
    tap(history)
    XCTAssertTrue(app.navigationBars["history"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["new-record"].exists && app.buttons["new-record"].isEnabled)
    showSidebar(app)
    capture(app, "native-navigation-system-tables")
    let close = app.buttons["Close workspace"]
    tap(close)
    tap(app.buttons["open-sample"])
    showSidebar(app)
    XCTAssertEqual(app.buttons.matching(identifier: "open-recent").count, 0)
    tap(app.buttons["sidebar-table-topics"])
    showSidebar(app)
    XCTAssertEqual(app.buttons.matching(identifier: "open-recent").count, 1)
    tap(close)
    tap(app.buttons["open-sample"])
    showSidebar(app)
    XCTAssertEqual(app.buttons.matching(identifier: "open-recent").count, 0)
  }

  private func openLocal() throws -> XCUIApplication {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      env["LIFE_UI_TEST_NAVIGATION_SIMULATOR"] == nil, "Requires the private navigation fixture")
    continueAfterFailure = false
    guard env["LIFE_UI_TEST_NAVIGATION_SIMULATOR"] == env["SIMULATOR_UDID"] else {
      throw NSError(
        domain: "NavigationUITests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Private simulator mismatch"])
    }
    let app = XCUIApplication()
    app.launch()
    tap(app.buttons["open-local"])
    let find = app.buttons["quick-find"]
    XCTAssertTrue(find.waitForExistence(timeout: 10))
    wait { find.isEnabled && find.isHittable }
    return app
  }

  private func setQuery(_ text: String, in app: XCUIApplication) {
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeKey("a", modifierFlags: .command)
    query.typeText(text)
  }

  private func showSidebar(_ app: XCUIApplication) {
    if app.buttons["quick-find-sidebar"].isHittable { return }
    tap(app.navigationBars.buttons["BackButton"].firstMatch)
    XCTAssertTrue(app.buttons["quick-find-sidebar"].waitForExistence(timeout: 5))
  }

  private func recentLabels(_ app: XCUIApplication) -> [String] {
    app.buttons.matching(identifier: "open-recent").allElementsBoundByIndex.map(\.label)
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    // The sidebar footer floats over the list; a row under it reports hittable
    // while taps land on the footer.
    let footer = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "saved on this device")
    ).firstMatch
    func visible() -> Bool {
      guard element.exists && element.isHittable && element.frame.height > 0 else { return false }
      return !footer.isHittable || element.frame.maxY <= footer.frame.minY
    }
    for _ in 0..<10 {
      if visible() { return }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(visible(), app.debugDescription)
  }

  private func tap(_ element: XCUIElement) {
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    wait { element.isHittable }
    element.tap()
  }

  private func expect(_ element: XCUIElement, value: String) {
    wait { element.exists && element.value as? String == value }
  }

  private func wait(
    _ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 10), .completed, file: file, line: line)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
