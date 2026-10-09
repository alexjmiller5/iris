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
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    if !app.windows.firstMatch.waitForExistence(timeout: 5) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }

    openHubConnection(app)
    click(app.textFields["hub-endpoint"])
    app.textFields["hub-endpoint"].typeText(endpoint)
    click(app.descendants(matching: .any)["Use existing token"].firstMatch)
    click(app.secureTextFields["hub-token"])
    app.secureTextFields["hub-token"].typeText("fixture")
    click(app.buttons["Connect"])
    XCTAssertTrue(
      app.staticTexts["Hub workspace · local replica"].waitForExistence(timeout: 30)
        || app.descendants(matching: .any)["record-grid"].firstMatch.waitForExistence(timeout: 30),
      app.debugDescription)

    openHubConnection(app)
    click(app.descendants(matching: .any)["backup-settings"].firstMatch)
    let seeded = app.buttons["Restore daily/life-2026-10-01T09-10-00.sql.gz"]
    XCTAssertTrue(seeded.waitForExistence(timeout: 15), app.debugDescription)
    capture(app, "mac-backup-settings")

    click(app.buttons["backup-now"])
    expectMessage(app, "The hub saved a backup")
    click(app.buttons["backup-copy-replica"])
    saveSystemFile(app)
    expectMessage(app, "Copied the SQLite database")
    click(app.buttons["backup-export-sql"])
    saveSystemFile(app)
    expectMessage(app, "Exported")
    capture(app, "mac-backup-exported")

    click(seeded)
    let widgets = app.descendants(matching: .any)["restore-row-widgets"].firstMatch
    XCTAssertTrue(widgets.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["restore-apply"].isEnabled)
    capture(app, "mac-restore-preview")
    click(app.textFields["restore-confirm"])
    app.textFields["restore-confirm"].typeText("replace")
    click(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "mac-restored")

    let recovery = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Restore recovery copy from'")
    ).firstMatch
    XCTAssertTrue(recovery.waitForExistence(timeout: 10), app.debugDescription)
    click(recovery)
    XCTAssertTrue(widgets.waitForExistence(timeout: 30))
    click(app.textFields["restore-confirm"])
    app.textFields["restore-confirm"].typeText("replace")
    click(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "mac-restore-undone")
  }

  private func openHubConnection(_ app: XCUIApplication) {
    click(app.descendants(matching: .any).matching(identifier: "workspace-menu").firstMatch)
    click(app.menuItems["Hub connection"])
  }

  private func expectMessage(_ app: XCUIApplication, _ text: String) {
    let message = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'backup-message' AND value CONTAINS %@", text)
    ).firstMatch
    let label = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'backup-message' AND label CONTAINS %@", text)
    ).firstMatch
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline, !message.exists, !label.exists {
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    XCTAssertTrue(message.exists || label.exists, app.debugDescription)
  }

  /// The macOS file exporter is a save sheet on the window.
  private func saveSystemFile(_ app: XCUIApplication) {
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 60), app.debugDescription)
    sheet.buttons["Save"].click()
    let replace = app.buttons["Replace"]
    if replace.waitForExistence(timeout: 2) { replace.click() }
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
  }

  private func click(_ element: XCUIElement) {
    XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing \(element)")
    element.click()
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
