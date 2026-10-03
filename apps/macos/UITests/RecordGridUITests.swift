import XCTest

@MainActor
final class RecordGridUITests: XCTestCase {
  func testCatalogColumnsOpenTheFullRecordEditor() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    let grid = app.tables["record-grid"]
    XCTAssertTrue(
      grid.waitForExistence(timeout: 15), "The Mac workspace needs a column-based table")
    XCTAssertTrue(grid.staticTexts["Title"].exists)
    XCTAssertTrue(grid.staticTexts["Status"].exists)
    XCTAssertTrue(grid.staticTexts["Draft"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-mac-record-grid"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    grid.buttons["Open A place to start"].click()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "A place to start")
    XCTAssertTrue(app.buttons["Edit Markdown"].exists)
    app.buttons["Cancel"].click()
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
  }
}
