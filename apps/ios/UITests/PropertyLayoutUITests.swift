import XCTest

@MainActor
final class PropertyLayoutUITests: XCTestCase {
  func testReorderedPropertiesPersistWithTitlePinned() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["saved-views"].tap()
    app.buttons["view-properties"].tap()
    let body = app.switches["property-visible-body"]
    let status = app.switches["property-visible-status"]
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    body.press(forDuration: 1)
    app.buttons["Move up"].tap()
    XCTAssertLessThan(body.frame.minY, status.frame.minY)
    app.buttons["apply-property-layout"].tap()
    let name = app.textFields["saved-view-name"]
    for _ in 0..<5 where !name.isHittable { app.swipeUp() }
    name.tap()
    name.typeText("Body first")
    app.buttons["save-view-copy"].tap()
    XCTAssertTrue(app.staticTexts["saved-view-receipt"].waitForExistence(timeout: 5))
    app.navigationBars["Saved views"].buttons["Done"].tap()
    app.buttons["saved-views"].tap()
    app.buttons["All records"].tap()
    app.buttons["saved-views"].tap()
    app.buttons["Body first"].tap()
    app.buttons["saved-views"].tap()
    app.buttons["view-properties"].tap()
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    XCTAssertLessThan(body.frame.minY, status.frame.minY, "The saved column order must persist")
    app.buttons["apply-property-layout"].tap()
    app.navigationBars["Saved views"].buttons["Done"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    XCTAssertTrue(app.textFields["field-title"].waitForExistence(timeout: 5))
    let content = app.descendants(matching: .any).matching(identifier: "field-body").firstMatch
    XCTAssertTrue(content.waitForExistence(timeout: 5))
    XCTAssertLessThan(
      app.textFields["field-title"].frame.minY, app.buttons["field-status"].frame.minY)
    XCTAssertLessThan(
      app.buttons["field-status"].frame.minY, content.frame.minY,
      "The full record places editable Content below its properties")
    XCTAssertTrue(app.webViews.textViews["Body"].waitForExistence(timeout: 10))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "reordered-properties-title-pinned"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

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
    let settings = XCTAttachment(screenshot: app.screenshot())
    settings.name = "record-property-settings"
    settings.lifetime = .keepAlways
    add(settings)
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
