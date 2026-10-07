import XCTest

@MainActor
final class PresentationUITests: XCTestCase {
  func testCalendarRangesGalleryAndBoardMove() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["LIFE_UI_TEST_CATALOG_CLEAN_HOST"] == "1")
    let path = try XCTUnwrap(environment["LIFE_UI_TEST_PRESENTATION_DATABASE"])
    XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "presentation-acceptance.sqlite")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    if !app.windows.firstMatch.waitForExistence(timeout: 3) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    let open = app.buttons["Open a local database…"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.typeText(path)
    location.typeKey(.return, modifierFlags: [])
    app.sheets.buttons["Open"].firstMatch.click()
    let table = app.buttons["sidebar-table-notes"]
    XCTAssertTrue(table.waitForExistence(timeout: 10))
    table.click()
    let navigationFinished = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: app.buttons["cancel-destination"])
    XCTAssertEqual(XCTWaiter.wait(for: [navigationFinished], timeout: 10), .completed)
    func layout(_ name: String) {
      app.buttons["view-options"].click()
      let picker = app.popUpButtons["view-layout"]
      XCTAssertTrue(picker.waitForExistence(timeout: 5))
      picker.click()
      app.menuItems[name].click()
      if name == "Calendar" {
        let endDate = app.popUpButtons["calendar-end-date"]
        XCTAssertTrue(endDate.waitForExistence(timeout: 5))
        endDate.click()
        app.menuItems["Ends"].click()
      }
      app.buttons["apply-view-options"].click()
    }
    layout("Calendar")
    let records = app.buttons.matching(NSPredicate(format: "label == %@", "A place to start"))
    XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(records.count, 3, "The record must appear on all three spanned dates")
    capture(app, "calendar-range")
    layout("Gallery")
    XCTAssertEqual(records.count, 1)
    records.firstMatch.click()
    XCTAssertTrue(app.textFields["field-title"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].firstMatch.click()
    layout("Board")
    XCTAssertTrue(app.staticTexts["Draft (1)"].waitForExistence(timeout: 5))
    app.menuButtons["Move"].click()
    app.menuItems["Ready"].click()
    XCTAssertTrue(app.staticTexts["Ready (1)"].waitForExistence(timeout: 5))
    records.firstMatch.click()
    XCTAssertTrue(app.popUpButtons["field-status"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.popUpButtons["field-status"].value as? String, "Ready")
    app.buttons["Cancel"].firstMatch.click()
    capture(app, "board-saved-move")
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
