import XCTest

@MainActor
final class BulkRecordUITests: XCTestCase {
  func testLoadedSelectionChangesAPropertyAndExportsSelection() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let menu = app.descendants(matching: .any).matching(identifier: "workspace-menu").firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 15))
    menu.click()
    let select = app.menuItems["select-loaded-rows"]
    XCTAssertTrue(select.waitForExistence(timeout: 3))
    XCTAssertTrue(select.isEnabled)
    select.click()
    let apply = app.buttons["bulk-apply"]
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertFalse(apply.isEnabled)
    app.buttons["bulk-select-all"].click()
    let input = app.textFields["bulk-value"]
    XCTAssertTrue(input.waitForExistence(timeout: 3))
    input.click()
    input.typeText("Changed by selection")
    XCTAssertTrue(apply.isEnabled)
    apply.click()
    XCTAssertTrue(
      app.staticTexts["1 succeeded, 0 failed, 0 unattempted"].waitForExistence(timeout: 10))
    app.buttons["bulk-done"].click()
    XCTAssertTrue(app.staticTexts["Changed by selection"].waitForExistence(timeout: 5))
    menu.click()
    app.menuItems["select-loaded-rows"].click()
    app.buttons["bulk-select-all"].click()
    app.buttons["bulk-export"].click()
    XCTAssertTrue(app.buttons["record-export-save"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Selected rows"].exists)
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = "native-selected-row-export"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
