import XCTest

@MainActor
final class RecordExportUITests: XCTestCase {
  func testCompactMenuOpensAndDismissesLoadedExport() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let actions = app.descendants(matching: .any).matching(identifier: "workspace-menu").firstMatch
    XCTAssertTrue(
      actions.waitForExistence(timeout: 5), "Export belongs in the compact workspace menu")
    actions.click()
    XCTAssertTrue(app.menuItems["Hub connection"].waitForExistence(timeout: 3))
    let export = app.menuItems["Export loaded rows"]
    XCTAssertTrue(export.exists && export.isEnabled)
    export.click()
    let save = app.buttons["record-export-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertTrue(save.isEnabled)
    capture(app, "native-loaded-export-sheet")
    app.buttons["record-export-done"].click()
    XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    XCTAssertTrue(grid.exists)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
