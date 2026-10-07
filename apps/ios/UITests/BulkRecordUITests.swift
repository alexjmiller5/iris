import XCTest

@MainActor
final class BulkRecordUITests: XCTestCase {
  func testSelectLoadedRowsChangesValueAndKeepsExportCompact() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["workspace-menu"].tap()
    app.buttons["Select loaded rows"].tap()
    let apply = app.buttons["bulk-apply"]
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertFalse(apply.isEnabled)
    app.buttons["bulk-select-all"].tap()
    let input = app.textFields["bulk-value"]
    XCTAssertTrue(input.waitForExistence(timeout: 3))
    input.tap()
    input.typeText("Selected synthetic note")
    apply.tap()
    XCTAssertTrue(app.staticTexts["bulk-result-summary"].waitForExistence(timeout: 10))
    XCTAssertEqual(
      app.staticTexts["bulk-result-summary"].label, "1 succeeded, 0 failed, 0 unattempted")
    app.buttons["bulk-done"].tap()
    let title = app.buttons["inline-property-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "Selected synthetic note")
    app.buttons["workspace-menu"].tap()
    app.buttons["Select loaded rows"].tap()
    app.buttons["bulk-select-all"].tap()
    app.buttons["bulk-export"].tap()
    XCTAssertTrue(app.buttons["record-export-save"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Selected rows"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "selected-row-export-ios"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
