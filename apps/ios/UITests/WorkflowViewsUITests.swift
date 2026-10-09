import XCTest

@MainActor
final class WorkflowViewsUITests: XCTestCase {
  func testDailyQueueActionAndOptionsSurviveReopening() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["IRIS_TEST_SAVED_VIEWS_SIMULATOR"] == nil)
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    let open = app.buttons["open-local"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.tap()
    let views = app.buttons["saved-views"]
    XCTAssertTrue(views.waitForExistence(timeout: 10))
    views.tap()
    let queue = app.buttons["Daily queue"]
    XCTAssertTrue(queue.waitForExistence(timeout: 5))
    queue.tap()
    let review = app.buttons["Mark reviewed"]
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    XCTAssertTrue(review.isEnabled)
    let before = XCTAttachment(screenshot: app.screenshot())
    before.name = "native-daily-queue"
    before.lifetime = .keepAlways
    add(before)
    app.buttons["filter-bar-sort"].tap()
    XCTAssertTrue(app.navigationBars["Sort"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["sort-direction-0"].exists)
    XCTAssertTrue(app.buttons["sort-direction-1"].exists)
    let options = XCTAttachment(screenshot: app.screenshot())
    options.name = "native-ordered-sorts"
    options.lifetime = .keepAlways
    add(options)
    app.otherElements["PopoverDismissRegion"].tap()
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    review.tap()
    XCTAssertTrue(review.waitForNonExistence(timeout: 5))
    views.tap()
    app.buttons["Default view"].tap()
    let record = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Viewfixture Alpha"))
      .firstMatch
    XCTAssertTrue(record.waitForExistence(timeout: 5))
    record.tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["field-status"].label.contains("Ready"))
    app.navigationBars["Record"].buttons["Cancel"].tap()
    views.tap()
    queue.tap()
    XCTAssertFalse(review.exists)
    let after = XCTAttachment(screenshot: app.screenshot())
    after.name = "native-reviewed-queue"
    after.lifetime = .keepAlways
    add(after)
  }
}
