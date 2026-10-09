import XCTest

/// Settings > Backup against `scripts/test-backup.ts <life-data> --serve` (the real hub
/// Worker over synthetic SQLite, token "fixture"). Set TEST_RUNNER_LIFE_UI_TEST_BACKUP_HUB.
@MainActor
final class BackupUITests: XCTestCase {
  func testHubBackupsCopyExportRestoreAndUndo() throws {
    guard let endpoint = ProcessInfo.processInfo.environment["LIFE_UI_TEST_BACKUP_HUB"] else {
      throw XCTSkip("Set LIFE_UI_TEST_BACKUP_HUB to the synthetic backup hub")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))

    // A replica of the synthetic hub: a file-backed workspace with hub backups.
    tap(app.buttons["workspace-menu"])
    tap(app.buttons["Hub connection"])
    tap(app.textFields["hub-endpoint"])
    app.textFields["hub-endpoint"].typeText(endpoint)
    tap(app.buttons["Use existing token"])
    tap(app.secureTextFields["hub-token"])
    app.secureTextFields["hub-token"].typeText("fixture")
    tap(app.buttons["Connect"])
    XCTAssertTrue(app.navigationBars["widgets"].waitForExistence(timeout: 30), app.debugDescription)
    openBackup(app)
    let seeded = app.buttons["Restore daily/life-2026-10-01T09-10-00.sql.gz"]
    XCTAssertTrue(seeded.waitForExistence(timeout: 15), app.debugDescription)
    capture(app, "ios-backup-settings")

    tap(app.buttons["backup-now"])
    expectMessage(app, "The hub saved a backup")
    capture(app, "ios-backup-now")

    tap(app.buttons["backup-copy-replica"])
    saveSystemFile(app)
    expectMessage(app, "Copied the SQLite database")
    tap(app.buttons["backup-export-sql"])
    saveSystemFile(app)
    expectMessage(app, "Exported")
    capture(app, "ios-backup-exported")

    tap(seeded)
    let widgets = app.descendants(matching: .any)["restore-row-widgets"]
    XCTAssertTrue(widgets.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertTrue(app.buttons["restore-apply"].exists && !app.buttons["restore-apply"].isEnabled)
    capture(app, "ios-restore-preview")
    tap(app.textFields["restore-confirm"])
    app.textFields["restore-confirm"].typeText("replace")
    tap(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "ios-restored")

    // Undo: restore the recovery copy saved before the first restore.
    let recovery = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Restore recovery copy from'")
    ).firstMatch
    XCTAssertTrue(recovery.waitForExistence(timeout: 10), app.debugDescription)
    tap(recovery)
    XCTAssertTrue(widgets.waitForExistence(timeout: 30))
    tap(app.textFields["restore-confirm"])
    app.textFields["restore-confirm"].typeText("replace")
    tap(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "ios-restore-undone")
  }

  private func openBackup(_ app: XCUIApplication) {
    tap(app.buttons["workspace-menu"])
    tap(app.buttons["Hub connection"])
    tap(app.buttons["backup-settings"])
    XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 10))
  }

  private func expectMessage(_ app: XCUIApplication, _ text: String) {
    let message = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'backup-message' AND label CONTAINS %@", text)
    ).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 120), app.debugDescription)
    XCTAssertFalse(app.staticTexts["backup-failure"].exists)
  }

  private func saveSystemFile(_ app: XCUIApplication) {
    let picker = app.otherElements["Browse View (Picker)"]
    XCTAssertTrue(picker.waitForExistence(timeout: 60), app.debugDescription)
    let save = app.buttons["DOCPicker.actionButton"]
    XCTAssertTrue(save.isEnabled)
    save.tap()
    if !picker.waitForNonExistence(timeout: 3) {
      let replace = app.buttons["Replace"]
      XCTAssertTrue(replace.waitForExistence(timeout: 3), app.debugDescription)
      replace.tap()
      XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
    }
  }

  /// Taps once the element can be hit, dismissing the system's password and keyboard
  /// tutorial prompts and scrolling the form as needed.
  private func tap(_ element: XCUIElement) {
    let app = XCUIApplication()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      let prompt = app.sheets["Save Password?"]
      if prompt.exists, prompt.buttons["Not Now"].isHittable {
        prompt.buttons["Not Now"].tap()
        _ = prompt.waitForNonExistence(timeout: 15)
        continue
      }
      let tutorial = app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Speed up your typing")
      ).firstMatch
      if tutorial.exists, app.buttons["Continue"].isHittable {
        app.buttons["Continue"].tap()
        continue
      }
      if element.exists, element.isHittable {
        element.tap()
        return
      }
      if element.exists { app.swipeUp() }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    XCTFail("Not tappable: \(element)\n\(app.debugDescription)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
