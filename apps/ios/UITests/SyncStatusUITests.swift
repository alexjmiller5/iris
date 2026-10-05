import XCTest

@MainActor
final class SyncStatusUITests: XCTestCase {
  func testStatusShowsProgressAndCancelsHeldSyncWithoutClosingWorkspace() async throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] == env["SIMULATOR_UDID"]
        && env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] != nil,
      "Use the explicitly selected disposable simulator and synthetic replica.")
    let endpoint = try XCTUnwrap(env["LIFE_UI_TEST_TABLE_NAV_HUB"])
    let url = try XCTUnwrap(URL(string: endpoint))
    XCTAssertEqual(url.host, "127.0.0.1")
    @Sendable func gate(_ action: String) async throws -> Bool {
      let (data, _) = try await URLSession.shared.data(
        from: XCTUnwrap(URL(string: endpoint + "/fixture/" + action)))
      return (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["waiting"] ?? false
    }
    addTeardownBlock { _ = try await gate("release") }
    _ = try await gate("hold")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    var waiting = false
    for _ in 0..<100 {
      waiting = try await gate("status")
      if waiting { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(waiting)
    app.buttons["workspace-status"].tap()
    let cancel = app.buttons["cancel-sync"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["sync-phase"].exists)
    XCTAssertTrue(app.staticTexts["sync-elapsed"].exists)
    XCTAssertFalse(app.buttons["sync-now"].isEnabled)
    capture(app, "sync-progress-held")
    cancel.tap()
    XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["sync-now"].isEnabled)
    XCTAssertFalse(app.staticTexts["Needs attention"].exists)
    let serverStillHeld = try await gate("status")
    XCTAssertTrue(
      serverStillHeld, "Client cancellation must finish before the controlled server release")
    capture(app, "sync-cancelled-workspace-retained")
    app.buttons["status-done"].tap()
    XCTAssertTrue(app.navigationBars["notes"].exists)
    XCTAssertTrue(app.buttons["quick-find"].isEnabled)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
