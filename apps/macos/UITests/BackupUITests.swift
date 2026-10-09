import XCTest

/// Settings > Backup on the Mac with synthetic files only. The sample workspace (in
/// memory) restores a synthetic dump and undoes it; an explicitly opened CLI file shows
/// its path and `life export`. Set TEST_RUNNER_LIFE_UI_TEST_BACKUP_DUMP (a .sql.gz),
/// TEST_RUNNER_LIFE_UI_TEST_BACKUP_CLI_DB (a CLI life.db) and
/// TEST_RUNNER_LIFE_UI_TEST_BACKUP_SAVE_DIR (an empty folder for the saved export).
@MainActor
final class BackupUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  func testSampleRestoresADumpAndUndoes() throws {
    guard let dump = environment["LIFE_UI_TEST_BACKUP_DUMP"],
      let saveDir = environment["LIFE_UI_TEST_BACKUP_SAVE_DIR"]
    else { throw XCTSkip("Set LIFE_UI_TEST_BACKUP_DUMP and LIFE_UI_TEST_BACKUP_SAVE_DIR") }
    continueAfterFailure = false
    let app = launch(["--demo"])
    defer { app.terminate() }
    openBackup(app)
    XCTAssertFalse(app.buttons["backup-copy-replica"].exists, "The sample has no file to copy")
    capture(app, "mac-backup-sample")

    click(app.buttons["backup-export-sql"])
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 30), app.debugDescription)
    goTo(app, saveDir)
    sheet.buttons["Save"].firstMatch.click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), app.debugDescription)
    expectMessage(app, "Exported")
    let saved = try FileManager.default.contentsOfDirectory(atPath: saveDir)
    XCTAssertEqual(saved.filter { $0.hasSuffix(".sql") }.count, 1, "\(saved)")
    capture(app, "mac-backup-exported")

    click(app.buttons["backup-choose-file"])
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    goTo(app, dump)
    app.sheets.buttons["Open"].firstMatch.click()
    let notes = app.descendants(matching: .any)["restore-row-notes"].firstMatch
    XCTAssertTrue(notes.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["restore-apply"].isEnabled, "Restore needs the typed word")
    capture(app, "mac-restore-preview")
    restore(app)
    capture(app, "mac-restored")

    let recovery = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Restore recovery copy from'")
    ).firstMatch
    click(recovery)
    XCTAssertTrue(notes.waitForExistence(timeout: 30))
    restore(app)
    capture(app, "mac-restore-undone")
  }

  func testSharedCLIFilePointsAtItsPathAndLifeExport() throws {
    guard let database = environment["LIFE_UI_TEST_BACKUP_CLI_DB"] else {
      throw XCTSkip("Set LIFE_UI_TEST_BACKUP_CLI_DB")
    }
    continueAfterFailure = false
    let app = launch(["--demo"])
    defer { app.terminate() }
    // The supported external-file picker on the welcome screen; never the app's own replica.
    click(app.buttons["Close workspace"])
    click(app.buttons["Open a local database…"])
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    goTo(app, database)
    app.sheets.buttons["Open"].firstMatch.click()
    openBackup(app)
    let path = app.descendants(matching: .any)["backup-shared-path"].firstMatch
    XCTAssertTrue(path.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertFalse(app.buttons["backup-copy-replica"].exists)
    XCTAssertFalse(app.buttons["backup-choose-file"].exists, "The CLI restores its own file")
    capture(app, "mac-backup-shared-cli-file")
  }

  private func launch(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments + ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 5) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    return app
  }

  /// On the Mac, Hub connection sits in the sidebar's bottom bar beside the sync pill.
  private func openBackup(_ app: XCUIApplication) {
    click(app.buttons["Hub connection"])
    click(app.descendants(matching: .any)["backup-settings"].firstMatch)
    XCTAssertTrue(app.buttons["backup-export-sql"].waitForExistence(timeout: 10))
  }

  private func restore(_ app: XCUIApplication) {
    let confirm = app.textFields["restore-confirm"]
    click(confirm)
    confirm.typeText("replace")
    click(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
  }

  /// Go to a folder or file in an open or save panel.
  private func goTo(_ app: XCUIApplication, _ path: String) {
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5), app.debugDescription)
    location.typeText(path)
    location.typeKey(.return, modifierFlags: [])
  }

  private func expectMessage(_ app: XCUIApplication, _ text: String) {
    let message = app.staticTexts.matching(
      NSPredicate(
        format: "identifier == 'backup-message' AND (value CONTAINS %@ OR label CONTAINS %@)",
        text, text)
    ).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 120), app.debugDescription)
    XCTAssertFalse(app.staticTexts["backup-failure"].exists)
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
