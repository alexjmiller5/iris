import XCTest

@MainActor
final class PageCaptureUITests: XCTestCase {
  func testExplicitCaptureActionPreservesNonCaptureRecordDraft() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    let row = app.buttons["Open A place to start"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.click()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.click()
    title.typeKey("a", modifierFlags: .command)
    title.typeText("Kept capture draft")
    let menu = app.descendants(matching: .any).matching(identifier: "record-menu").firstMatch
    XCTAssertTrue(menu.exists)
    menu.click()
    let capture = app.menuItems["Open as page capture"]
    XCTAssertTrue(capture.waitForExistence(timeout: 3))
    capture.click()
    XCTAssertTrue(
      app.staticTexts["Capture metadata is missing or invalid."].waitForExistence(timeout: 5))
    app.buttons["OK"].click()
    XCTAssertEqual(title.value as? String, "Kept capture draft")
    XCTAssertTrue(app.buttons["done-record"].exists)
    XCTAssertFalse(app.buttons["capture-save-png"].exists)
  }
}
