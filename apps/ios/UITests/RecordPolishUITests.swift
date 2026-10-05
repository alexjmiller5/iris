import XCTest

@MainActor
final class RecordPolishUITests: XCTestCase {
  func testReadOnlyPropertiesStayVisibleAndReferenceStillOpens() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] != nil
        && env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] == env["SIMULATOR_UDID"],
      "Use the explicitly selected synthetic simulator fixture.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-local"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    app.buttons["System tables"].tap()
    let table = app.buttons["sidebar-table-readonly_notes"]
    for _ in 0..<8 where !table.isHittable { app.swipeUp() }
    table.tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read-only title"))
      .firstMatch.tap()
    XCTAssertTrue(app.staticTexts["record-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["record-heading"].label, "Read-only title")
    XCTAssertTrue(app.staticTexts["Visible read-only detail"].isHittable)
    XCTAssertFalse(app.staticTexts["opaque-fixture-record"].exists)
    capture(app, "read-only-title-and-properties")
    let reference = app.buttons["Open Linked fixture topic"]
    XCTAssertTrue(reference.waitForExistence(timeout: 5))
    reference.tap()
    XCTAssertTrue(app.staticTexts["record-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["record-heading"].label, "Linked fixture topic")
  }

  func testRulesAreBottomLinkAndReturningPreservesDraft() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] != nil
        && env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] == env["SIMULATOR_UDID"],
      "Use the explicitly selected synthetic simulator fixture.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-local"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    capture(app, "record-list-before-opening")
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    capture(app, "record-open-before-rules")
    XCTAssertTrue(title.isHittable, "Catalog rules must not push the title offscreen")
    XCTAssertLessThan(title.frame.minY, app.frame.height * 0.5)
    title.tap()
    title.typeText(" retained draft")
    let draft = title.value as? String
    let rules = app.buttons["catalog-rules"]
    for _ in 0..<12 where !rules.isHittable { app.swipeUp() }
    XCTAssertTrue(rules.isHittable)
    rules.tap()
    XCTAssertTrue(app.navigationBars["Catalog rules"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Keep a useful record title.")
      ).firstMatch.exists)
    capture(app, "record-catalog-rules-page")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    for _ in 0..<12 where !title.isHittable { app.swipeDown() }
    XCTAssertEqual(title.value as? String, draft)
    capture(app, "record-draft-after-rules")
    app.navigationBars.buttons["Cancel"].tap()
    app.buttons["Discard changes"].tap()
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
