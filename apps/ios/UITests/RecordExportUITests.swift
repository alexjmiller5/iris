import XCTest

@MainActor
final class RecordExportUITests: XCTestCase {
  func testSystemExporterCanCancelRetryAndSaveJSONAndCSV() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["workspace-menu"].tap()
    app.buttons["Export loaded rows"].tap()
    let save = app.buttons["record-export-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    save.tap()
    let pickerBar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
    XCTAssertTrue(pickerBar.waitForExistence(timeout: 10), app.debugDescription)
    capture(app, "native-export-system-cancel")
    // Dismiss the system sheet through its visible header. Current iOS also exposes
    // a stale, non-hittable Cancel accessibility node over its More button.
    pickerBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    XCTAssertTrue(app.otherElements["Browse View (Picker)"].waitForNonExistence(timeout: 5))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: save)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, app.debugDescription)
    XCTAssertFalse(app.staticTexts["record-export-error"].exists)

    save.tap()
    saveSystemFile(app, screenshot: "native-export-json-save")
    app.buttons["record-export-format"].tap()
    app.buttons["CSV (spreadsheet)"].tap()
    XCTAssertEqual(save.label, "Save CSV…")
    save.tap()
    saveSystemFile(app, screenshot: "native-export-csv-save")
    let metadata = app.buttons["record-export-metadata"]
    XCTAssertTrue(metadata.waitForExistence(timeout: 5))
    metadata.tap()
    saveSystemFile(app, screenshot: "native-export-metadata-save")
    capture(app, "native-export-csv-complete")
    app.buttons["record-export-done"].tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 5))
  }

  private func saveSystemFile(_ app: XCUIApplication, screenshot: String) {
    let picker = app.otherElements["Browse View (Picker)"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
    let save = app.buttons["DOCPicker.actionButton"]
    XCTAssertTrue(save.isEnabled)
    capture(app, screenshot)
    save.tap()
    if !picker.waitForNonExistence(timeout: 3) {
      let replace = app.buttons["Replace"]
      XCTAssertTrue(replace.waitForExistence(timeout: 3), app.debugDescription)
      replace.tap()
      XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
    }
    XCTAssertTrue(app.buttons["record-export-save"].isEnabled)
    XCTAssertFalse(app.staticTexts["record-export-error"].exists)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testWorkspaceMenuOpensAndDismissesLoadedExport() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["workspace-menu"].tap()
    let export = app.buttons["Export loaded rows"]
    XCTAssertTrue(export.waitForExistence(timeout: 5))
    XCTAssertTrue(export.isEnabled)
    export.tap()
    let save = app.buttons["record-export-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertTrue(save.isEnabled)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "native-loaded-export-sheet"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["record-export-done"].tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["notes"].exists)
  }
}
