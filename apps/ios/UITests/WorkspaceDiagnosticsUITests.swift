import XCTest

@MainActor
final class WorkspaceDiagnosticsUITests: XCTestCase {
  func testCopyDiagnosticsAcknowledgesAndReturnsToRecords() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["workspace-status"].tap()
    XCTAssertTrue(app.navigationBars["Workspace status"].waitForExistence(timeout: 5))
    let copy = app.buttons["copy-diagnostics"]
    XCTAssertTrue(
      copy.waitForExistence(timeout: 5), "Status must offer an explicit diagnostic copy")
    XCTAssertTrue(copy.isHittable)
    XCTAssertEqual(copy.label, "Copy diagnostics")
    copy.tap()
    XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "synthetic-diagnostics-copied"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["status-done"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 5))
    // Clipboard content is verified externally using simctl pbpaste. A runner read triggers
    // cross-app paste permission and cannot establish what the application actually copied.
  }
}
