import XCTest

@MainActor
final class RecordGridUITests: XCTestCase {
  func testSingleClickEditsAndClickingAwaySavesWithoutActionButtons() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    grid.staticTexts.matching(NSPredicate(format: "value == %@", "A place to start")).firstMatch
      .click()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["inline-done"].exists)
    XCTAssertFalse(app.buttons["inline-open-record"].exists)
    XCTAssertFalse(app.buttons["undo-inline"].exists)
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Changed inside the table")
    grid.staticTexts.matching(NSPredicate(format: "value == %@", "Draft")).firstMatch.click()
    XCTAssertTrue(
      grid.staticTexts.matching(NSPredicate(format: "value == %@", "Changed inside the table"))
        .firstMatch.waitForExistence(timeout: 5))
    let ready = app.buttons["choice-status-Ready"]
    XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    XCTAssertFalse(ready.exists, "Clicking away must not open the clicked cell")
    grid.staticTexts.matching(NSPredicate(format: "value == %@", "Draft")).firstMatch.click()
    XCTAssertTrue(ready.waitForExistence(timeout: 5), "The next click exposes the actual choices")
    ready.click()
    XCTAssertTrue(
      grid.staticTexts.matching(NSPredicate(format: "value == %@", "Ready"))
        .firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["choice-status-Ready"].exists)
    grid.staticTexts.matching(NSPredicate(format: "value == %@", "Ready")).firstMatch.click()
    XCTAssertTrue(ready.waitForExistence(timeout: 5))
    let open = grid.buttons["Open Changed inside the table"]
    open.click()
    XCTAssertTrue(ready.waitForNonExistence(timeout: 5))
    XCTAssertFalse(field.exists, "Dismissal must not open the record underneath")
    open.click()
    XCTAssertTrue(field.waitForExistence(timeout: 5), "The next click can open the full record")
    capture(app, name: "single-click-cell-editing")
  }

  func testPropertyHelpAppearsBesideItsButton() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    grid.buttons["Open A place to start"].click()
    let info = app.buttons["About Status"]
    XCTAssertTrue(info.waitForExistence(timeout: 5))
    let anchor = info.frame
    info.click()
    let help = app.staticTexts.matching(
      NSPredicate(format: "value CONTAINS %@", "Choose Draft or Ready.")
    ).firstMatch
    XCTAssertTrue(help.waitForExistence(timeout: 5))
    capture(app, name: "property-help-anchor")
    let popup = help.frame
    let dx = max(anchor.minX - popup.maxX, popup.minX - anchor.maxX, 0)
    let dy = max(anchor.minY - popup.maxY, popup.minY - anchor.maxY, 0)
    XCTAssertLessThan(
      hypot(dx, dy), 48, "Property help must be anchored to the clicked info button")
  }

  func testColumnTitleOpensSortingAndAPropertyFilter() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let header = grid.buttons.matching(NSPredicate(format: "title == %@", "Status")).firstMatch
    XCTAssertTrue(header.exists)
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(app.menuItems["Sort ascending"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Sort descending"].exists)
    capture(app, name: "column-header-menu")
    app.menuItems["Sort descending"].click()
    XCTAssertTrue(header.waitForExistence(timeout: 3))
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    app.menuItems["Filter…"].click()
    let ready = app.descendants(matching: .any)["filter-option-Ready"]
    XCTAssertTrue(ready.waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["filter-chip-0"].exists)
    ready.click()
    capture(app, name: "column-header-filter-chip")
    XCTAssertTrue(app.staticTexts["No records"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testCatalogColumnsOpenTheFullRecordEditor() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(
      grid.waitForExistence(timeout: 15), "The Mac workspace needs a column-based table")
    for header in ["Title", "Status"] {
      XCTAssertTrue(
        grid.buttons.matching(NSPredicate(format: "title == %@", header)).firstMatch.exists)
    }
    XCTAssertTrue(
      grid.staticTexts.matching(NSPredicate(format: "value == %@", "Draft")).firstMatch.exists)
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "native-mac-record-grid"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    grid.buttons["Open A place to start"].click()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "A place to start")
    XCTAssertTrue(
      app.sheets.descendants(matching: .any).matching(identifier: "field-body").firstMatch.exists)
    XCTAssertTrue(app.sheets.webViews.textViews["Body"].waitForExistence(timeout: 10))
    app.buttons["done-record"].click()
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
  }
}
