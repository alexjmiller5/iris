import XCTest

@MainActor
final class RecordGridUITests: XCTestCase {
  func testDoubleClickEditsInlineAndCanStillExpandTheRecord() throws {
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
      .doubleClick()
    let field = grid.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertFalse(app.buttons["new-record"].isEnabled)
    XCTAssertTrue(
      app.buttons["Close workspace"].isEnabled, "Close dismisses the inline editor itself")
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Changed inside the table")
    let selectedRow = grid.tableRows.matching(NSPredicate(format: "selected == true")).firstMatch
    XCTAssertTrue(selectedRow.exists)
    XCTAssertGreaterThanOrEqual(field.frame.minY, selectedRow.frame.minY)
    XCTAssertLessThanOrEqual(grid.buttons["inline-done"].frame.maxY, selectedRow.frame.maxY)
    capture(app, name: "inline-text-edit")
    grid.buttons["inline-open-record"].click()
    let fullField = app.sheets.textFields["field-title"]
    XCTAssertTrue(fullField.waitForExistence(timeout: 5))
    XCTAssertEqual(fullField.value as? String, "Changed inside the table")
    app.buttons["done-record"].click()
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    XCTAssertTrue(
      grid.staticTexts.matching(NSPredicate(format: "value == %@", "Changed inside the table"))
        .firstMatch.waitForExistence(timeout: 5))
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
