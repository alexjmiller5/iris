import XCTest

@MainActor
final class PropertyLayoutUITests: XCTestCase {
  func testTitleOnlyViewKeepsHiddenEditableProperties() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["saved-views"].tap()
    app.buttons["view-properties"].tap()
    XCTAssertTrue(app.navigationBars["Properties"].waitForExistence(timeout: 5))
    app.buttons["properties-title-only"].tap()
    app.buttons["apply-property-layout"].tap()
    let name = app.textFields["saved-view-name"]
    for _ in 0..<5 where !name.isHittable { app.swipeUp() }
    name.tap()
    name.typeText("Title focus")
    app.buttons["save-view-copy"].tap()
    XCTAssertTrue(app.staticTexts["saved-view-receipt"].waitForExistence(timeout: 5))
    app.navigationBars["Saved views"].buttons["Done"].tap()
    app.buttons["saved-views"].tap()
    app.buttons["All records"].tap()
    app.buttons["saved-views"].tap()
    app.buttons["Title focus"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    XCTAssertTrue(app.textFields["field-title"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["field-status"].exists)
    let more = app.staticTexts["More properties"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.tap()
    let status = app.buttons["field-status"]
    for _ in 0..<5 where !status.isHittable { app.swipeUp() }
    XCTAssertTrue(status.isHittable)
    status.tap()
    app.buttons["Ready"].tap()
    app.buttons["save-record"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    app.staticTexts["More properties"].tap()
    XCTAssertTrue(app.buttons["field-status"].label.contains("Ready"))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "title-view-hidden-property-preserved"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
