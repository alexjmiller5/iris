import XCTest

@MainActor
final class RecordGridUITests: XCTestCase {
  func testCatalogColumnsOpenTheFullRecordEditor() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    // SwiftUI exposes a macOS Table as an outline on current releases.
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(
      grid.waitForExistence(timeout: 15), "The Mac workspace needs a column-based table")
    for header in ["Title", "Status"] {
      XCTAssertTrue(
        grid.buttons.matching(NSPredicate(format: "title == %@", header)).firstMatch.exists)
    }
    XCTAssertTrue(
      grid.staticTexts.matching(NSPredicate(format: "value == %@", "Draft")).firstMatch.exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-mac-record-grid"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    grid.buttons["Open A place to start"].click()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "A place to start")
    XCTAssertTrue(app.buttons["field-body"].exists)
    app.buttons["Cancel"].click()
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
  }
}
