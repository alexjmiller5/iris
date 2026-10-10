import XCTest

@MainActor
final class PageCaptureUITests: XCTestCase {
  func testExplicitCaptureActionKeepsAnOrdinaryRecordOpen() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A place to start"))
      .firstMatch
    if !row.waitForExistence(timeout: 3) {
      let table = app.buttons["sidebar-table-notes"]
      XCTAssertTrue(table.waitForExistence(timeout: 10))
      table.tap()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    let menu = app.buttons["record-menu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    app.buttons["open-page-capture"].tap()
    XCTAssertTrue(
      app.staticTexts["Capture metadata is missing or invalid."].waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "capture-invalid-metadata-visible"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.alerts.buttons["OK"].tap()
    XCTAssertTrue(app.buttons["done-record"].exists)
    XCTAssertFalse(app.buttons["capture-save-png"].exists)
  }
}
