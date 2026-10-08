import XCTest

/// The Mac filter bar on a synthetic database file: the column header adds a chip
/// whose select editor narrows the grid at once, Sort orders it, closing a popover
/// saves the table's default view, Undo reverts the latest save and a relaunch
/// reopens the saved filter.
@MainActor
final class FilterBarUITests: XCTestCase {
  func testHeaderChipSortUndoAndRelaunch() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["LIFE_UI_TEST_CATALOG_CLEAN_HOST"] == "1")
    let path = try XCTUnwrap(environment["LIFE_UI_TEST_FILTER_BAR_DATABASE"])
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    window(app)
    // The clean runner can retain the preceding test's synthetic file selection.
    let previous = app.buttons["Close workspace"]
    if previous.waitForExistence(timeout: 3) { previous.click() }
    let open = app.buttons["Open a local database…"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.typeText(path)
    location.typeKey(.return, modifierFlags: [])
    app.sheets.buttons["Open"].firstMatch.click()

    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let header = grid.buttons.matching(NSPredicate(format: "title == %@", "Status")).firstMatch
    XCTAssertTrue(header.waitForExistence(timeout: 5))
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    app.menuItems["Filter…"].click()
    let ready = app.descendants(matching: .any)["filter-option-Ready"]
    XCTAssertTrue(ready.waitForExistence(timeout: 5))
    ready.click()
    capture(app, "mac-2-chip-editing-select")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["No records"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
    capture(app, "mac-3-narrowed-grid")

    app.buttons["filter-bar-filter"].click()
    XCTAssertTrue(app.descendants(matching: .any)["filter-property-title"].waitForExistence(timeout: 5))
    capture(app, "mac-1-filter-popover")
    app.typeKey(.escape, modifierFlags: [])

    app.buttons["filter-bar-sort"].click()
    let add = app.descendants(matching: .any)["add-sort"]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.click()
    app.menuItems["Title"].click()
    let direction = app.buttons["sort-direction-0"]
    XCTAssertTrue(direction.waitForExistence(timeout: 5))
    direction.click()
    capture(app, "mac-4-sort-popover")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.buttons["sort-chip"].waitForExistence(timeout: 5))

    // The sort's save is the latest change; Undo reverts only it.
    let undo = app.buttons["undo-saved-change"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5))
    undo.click()
    let sortGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["sort-chip"])
    XCTAssertEqual(XCTWaiter.wait(for: [sortGone], timeout: 10), .completed)
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
    capture(app, "mac-5-undo-reverted-sort")

    app.terminate()
    app.launch()
    app.activate()
    window(app)
    let chip = app.buttons["filter-chip-0"]
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    XCTAssertEqual(chip.label, "Status: Ready")
    XCTAssertFalse(app.buttons["sort-chip"].exists)
    XCTAssertTrue(app.staticTexts["No records"].waitForExistence(timeout: 5))
    capture(app, "mac-6-relaunch-saved-filter")
    app.buttons["Close workspace"].click()
  }

  private func window(_ app: XCUIApplication) {
    if !app.windows.firstMatch.waitForExistence(timeout: 3) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
