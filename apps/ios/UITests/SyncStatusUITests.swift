import XCTest

@MainActor
final class SyncStatusUITests: XCTestCase {
  /// One pill reports every automatic-sync state; no surface offers a manual sync.
  func testPillReportsSyncingSyncedOfflinePendingAndRejectedWithoutSyncButtons() async throws {
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
    addTeardownBlock {
      _ = try await gate("release")
      _ = try await gate("mode/offline")
    }
    _ = try await gate("mode/accept")
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
    let pill = app.navigationBars["notes"].buttons["workspace-status"]
    expect(pill, "Syncing")
    capture(app, "pill-syncing")
    pill.tap()
    XCTAssertTrue(app.staticTexts["sync-phase"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["cancel-sync"].exists)
    XCTAssertFalse(app.buttons["sync-now"].exists)
    capture(app, "status-sheet-syncing")
    app.buttons["status-done"].tap()

    _ = try await gate("release")
    expect(pill, "Synced")
    capture(app, "pill-synced")

    _ = try await gate("mode/offline")
    expect(pill, "Offline")
    app.buttons["inline-property-title"].firstMatch.tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    title.typeText(" kept offline")
    app.buttons["inline-save"].tap()
    expect(pill, "Offline · 1 pending")
    XCTAssertFalse(app.staticTexts["Saving…"].exists)
    capture(app, "pill-offline-pending")

    // Returning to the foreground retries at once instead of waiting out the backoff.
    _ = try await gate("mode/reject")
    XCUIDevice.shared.press(.home)
    app.activate()
    expect(pill, "1 rejected")
    capture(app, "pill-rejected")
    pill.tap()
    XCTAssertTrue(app.navigationBars["Issues"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["refresh-rejected-edits"].exists)
    capture(app, "pill-opens-rejection-inbox")
  }

  private func expect(_ pill: XCUIElement, _ value: String) {
    let state = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", value), object: pill)
    XCTAssertEqual(
      XCTWaiter.wait(for: [state], timeout: 20), .completed,
      "Pill stayed \(pill.label) instead of \(value)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
