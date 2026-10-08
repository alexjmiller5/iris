import XCTest

@MainActor final class QuickAddUITests: XCTestCase {
  func testPendingIntentSurvivesRelaunchAndSavesOnlyOnExplicitAction() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    if !app.navigationBars["notes"].waitForExistence(timeout: 3) {
      app.buttons["Open local workspace"].tap()
    }
    let pending = app.buttons["open-quick-add"]
    XCTAssertTrue(pending.waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    if !app.navigationBars["notes"].waitForExistence(timeout: 3) {
      app.buttons["Open local workspace"].tap()
    }
    XCTAssertTrue(pending.waitForExistence(timeout: 15))
    pending.tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    title.tap()
    title.typeText("Quick Add fixture saved")
    let draft = XCTAttachment(screenshot: app.screenshot())
    draft.name = "quick-add-prepared-draft"
    draft.lifetime = .keepAlways
    add(draft)
    app.buttons["save-record"].tap()
    let saved = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Quick Add fixture saved")
    ).firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 15))
    XCTAssertFalse(pending.exists)
    saved.tap()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "Quick Add fixture saved")
    let reopened = XCTAttachment(screenshot: app.screenshot())
    reopened.name = "quick-add-saved-reopened"
    reopened.lifetime = .keepAlways
    add(reopened)
  }
}
