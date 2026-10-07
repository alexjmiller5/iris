import XCTest

@MainActor final class WidgetSettingsUITests: XCTestCase {
  func testTableSourceSurvivesRelaunchAndCanBeRemoved() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    openWorkspace(app)
    app.buttons["workspace-menu"].tap()
    app.buttons["widget-settings"].tap()
    XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 5))
    app.buttons["widget-enable-source"].tap()
    let enabled = app.staticTexts["widget-enabled-notes"]
    XCTAssertTrue(enabled.waitForExistence(timeout: 15))
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    openWorkspace(app)
    app.buttons["workspace-menu"].tap()
    app.buttons["widget-settings"].tap()
    XCTAssertTrue(enabled.waitForExistence(timeout: 5))
    app.buttons["widget-remove-notes"].tap()
    XCTAssertTrue(app.staticTexts["No sources enabled"].waitForExistence(timeout: 10))
    let receipt = XCTAttachment(screenshot: app.screenshot())
    receipt.name = "widget-source-removed"
    receipt.lifetime = .keepAlways
    add(receipt)
    app.buttons["Done"].tap()
  }

  private func openWorkspace(_ app: XCUIApplication) {
    if app.navigationBars["notes"].waitForExistence(timeout: 3) { return }
    app.buttons["Open my workspace"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
  }
}
