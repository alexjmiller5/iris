import XCTest

/// Needs `DueTimeUIFixtureTests` on the same private simulator first
/// (TEST_RUNNER_IRIS_TEST_DUE_TIME_SIMULATOR=<udid>).
@MainActor
final class DueTimeUITests: XCTestCase {
  func testAddTimeToggleAndDueTimeAlertSettings() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["IRIS_TEST_DUE_TIME_SIMULATOR"] != nil
        && env["IRIS_TEST_DUE_TIME_SIMULATOR"] == env["SIMULATOR_UDID"],
      "Prepare DueTimeUIFixtureTests on the explicitly allocated private simulator.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-local"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    let record = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Due fixture note")
    )
    .firstMatch
    XCTAssertTrue(record.waitForExistence(timeout: 15))
    record.tap()
    let toggle = app.switches["date-time-toggle-due"]
    for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(toggle.value as? String, "0")
    XCTAssertTrue(app.staticTexts["Add time"].exists, "The switch keeps its visible text")
    toggle.switches.firstMatch.tap()
    XCTAssertEqual(toggle.value as? String, "1")
    capture(app, "ios-due-add-time-on")
    let source = app.buttons["date-source-due"]
    source.tap()
    let field = app.textFields["field-due"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertTrue((field.value as? String ?? "").hasSuffix("T09:00"), "\(field.value ?? "")")
    toggle.switches.firstMatch.tap()
    XCTAssertEqual(toggle.value as? String, "0")
    XCTAssertEqual((field.value as? String)?.count, 10, "Removing the time returns to date-only")
    toggle.switches.firstMatch.tap()
    capture(app, "ios-due-source-with-time")
    app.buttons["done-record"].tap()
    XCTAssertTrue(record.waitForExistence(timeout: 10))
    capture(app, "ios-due-list-with-time")

    let hubConnection = app.buttons["Hub connection"]
    for _ in 0..<4 where !hubConnection.exists {
      app.buttons["workspace-menu"].tap()
      _ = hubConnection.waitForExistence(timeout: 3)
    }
    hubConnection.tap()
    let alerts = app.buttons["due-alert-settings"]
    for _ in 0..<4 where !alerts.isHittable { app.swipeUp() }
    alerts.tap()
    XCTAssertTrue(app.navigationBars["Due-time alerts"].waitForExistence(timeout: 5))
    let view = app.switches["due-alert-Due today"]
    XCTAssertTrue(view.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertEqual(view.value as? String, "0", "No view notifies by default")
    view.switches.firstMatch.tap()
    XCTAssertEqual(view.value as? String, "1")
    // Permission comes only from Enable alerts; this screen never asks.
    XCTAssertTrue(app.staticTexts["due-alerts-permission"].exists)
    XCTAssertFalse(app.alerts.firstMatch.exists)
    capture(app, "ios-due-time-alerts")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
