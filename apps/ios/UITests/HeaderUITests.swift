import XCTest

@MainActor
final class HeaderUITests: XCTestCase {
  func testEmptyWorkspaceHeaderKeepsTitleVisibleAndControlsCompact() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      environment["LIFE_UI_TEST_HEADER_SIMULATOR"] == environment["SIMULATOR_UDID"]
        && environment["LIFE_UI_TEST_HEADER_SIMULATOR"] != nil,
      "Seed the header fixture on an explicitly selected disposable simulator first.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["open-local"].waitForExistence(timeout: 10))
    app.buttons["open-local"].tap()
    try assertHeader(app, title: "Workspace")
  }

  func testTableHeaderKeepsTitleVisibleAndControlsCompact() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    try assertHeader(app, title: "notes")
    viewsOpen(app)
  }

  private func assertHeader(_ app: XCUIApplication, title name: String) throws {
    let bar = app.navigationBars[name]
    XCTAssertTrue(bar.waitForExistence(timeout: 15))
    let views = app.buttons["saved-views"]
    XCTAssertTrue(views.waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "iphone-header-" + name
    shot.lifetime = .keepAlways
    add(shot)
    let title = bar.staticTexts[name]
    XCTAssertTrue(title.exists)
    XCTAssertTrue(title.isHittable)
    XCTAssertLessThanOrEqual(title.frame.maxY, views.frame.minY)
    XCTAssertLessThanOrEqual(
      bar.frame.height, 64, "Use a compact navigation title above table controls")
    XCTAssertGreaterThan(views.frame.minY, app.frame.height * 0.7)
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.exists)
    XCTAssertGreaterThan(
      list.frame.height, app.frame.height * 0.5,
      "Native controls must leave the records most of the screen")
    XCTAssertTrue(views.isHittable)
  }

  private func viewsOpen(_ app: XCUIApplication) {
    app.buttons["saved-views"].tap()
    XCTAssertTrue(app.navigationBars["Saved views"].waitForExistence(timeout: 5))
  }
}
