import XCTest

/// Settings > Backup against `scripts/test-backup.ts <soma> --serve` (the real hub
/// Worker over synthetic SQLite, token "fixture"). Set TEST_RUNNER_IRIS_TEST_BACKUP_HUB.
@MainActor
final class BackupUITests: XCTestCase {
  func testHubBackupsCopyExportRestoreAndUndo() throws {
    guard let endpoint = ProcessInfo.processInfo.environment["IRIS_TEST_BACKUP_HUB"] else {
      throw XCTSkip("Set IRIS_TEST_BACKUP_HUB to the synthetic backup hub")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    // A saved connection to this hub resumes from the Keychain, which avoids iOS's
    // Save Password sheet; the first run on a fresh simulator connects by token.
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    if !app.navigationBars["widgets"].waitForExistence(timeout: 20) {
      connect(app, endpoint: endpoint)
    }
    openBackup(app)
    let seeded = app.buttons["Restore daily/soma-2026-10-01T09-10-00.sql.gz"]
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
    capture(app, "ios-restore-preview")
    tap(app.textFields["restore-confirm"])
    XCTAssertFalse(app.buttons["restore-apply"].isEnabled, "Restore needs the typed word")
    app.textFields["restore-confirm"].typeText("replace")
    capture(app, "ios-restore-confirmed")
    tap(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "ios-restored")

    // Undo: restore the recovery copy saved before the first restore.
    let recovery = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Restore recovery copy from'")
    ).firstMatch
    tap(recovery)
    XCTAssertTrue(widgets.waitForExistence(timeout: 30))
    tap(app.textFields["restore-confirm"])
    app.textFields["restore-confirm"].typeText("replace")
    tap(app.buttons["restore-apply"])
    expectMessage(app, "Restored")
    capture(app, "ios-restore-undone")
  }

  private func connect(_ app: XCUIApplication, endpoint: String) {
    // The toolbar settles after launch; a tap during that can land on New record.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let hubConnection = app.buttons["Hub connection"]
    for _ in 0..<4 where !hubConnection.exists {
      if app.navigationBars["New record"].exists { app.buttons["Cancel"].tap() }
      tap(app.buttons["workspace-menu"])
      _ = hubConnection.waitForExistence(timeout: 3)
    }
    tap(hubConnection)
    tap(app.textFields["hub-endpoint"])
    app.textFields["hub-endpoint"].typeText(endpoint)
    tap(app.buttons["Use existing token"])
    tap(app.secureTextFields["hub-token"])
    app.secureTextFields["hub-token"].typeText("fixture")
    tap(app.buttons["Connect"])
    XCTAssertTrue(app.navigationBars["widgets"].waitForExistence(timeout: 30), app.debugDescription)
    // iOS offers to save the token as a password a moment after Connect.
    let prompt = app.sheets["Save Password?"]
    if prompt.waitForExistence(timeout: 10) {
      for _ in 0..<5 where prompt.exists {
        prompt.buttons["Not Now"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = prompt.waitForNonExistence(timeout: 5)
      }
    }
  }

  /// The menu can swallow a tap while it animates or a system prompt passes; retry.
  private func openBackup(_ app: XCUIApplication) {
    let link = app.buttons["backup-settings"]
    for _ in 0..<5 where !link.exists {
      tap(app.buttons["workspace-menu"])
      let item = app.buttons["Hub connection"]
      if item.waitForExistence(timeout: 5) { item.tap() }
      _ = link.waitForExistence(timeout: 5)
    }
    tap(link)
    XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 10))
  }

  /// The result line sits at the top of the form; scroll back to it while waiting.
  private func expectMessage(_ app: XCUIApplication, _ text: String) {
    let message = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'backup-message' AND label CONTAINS %@", text)
    ).firstMatch
    let deadline = Date().addingTimeInterval(120)
    while !message.waitForExistence(timeout: 3), Date() < deadline {
      if app.staticTexts["backup-failure"].exists { break }
      app.swipeDown()
    }
    XCTAssertTrue(message.exists, app.debugDescription)
    XCTAssertFalse(app.staticTexts["backup-failure"].exists)
  }

  private func saveSystemFile(_ app: XCUIApplication) {
    let picker = app.otherElements["Browse View (Picker)"]
    XCTAssertTrue(picker.waitForExistence(timeout: 60), app.debugDescription)
    let save = app.buttons["DOCPicker.actionButton"]
    XCTAssertTrue(save.isEnabled)
    save.tap()
    if !picker.waitForNonExistence(timeout: 15) {
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
      // A toolbar control can report not hittable while it is visibly enabled.
      if element.exists, element.isEnabled, element.frame.minY < 140, Date() > deadline.addingTimeInterval(-15) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return
      }
      // Form rows below the fold are not in the hierarchy until scrolled to.
      if element.exists || Date() > deadline.addingTimeInterval(-15) { app.swipeUp() }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    XCTFail("Not tappable: \(element)\n\(app.debugDescription)")
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let prompt = app.sheets["Save Password?"]
    if prompt.exists, prompt.buttons["Not Now"].isHittable {
      prompt.buttons["Not Now"].tap()
      _ = prompt.waitForNonExistence(timeout: 15)
    }
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
