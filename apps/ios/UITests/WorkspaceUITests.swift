import UIKit
import XCTest

@MainActor
final class WorkspaceUITests: XCTestCase {
  func testPendingRecoveryCanCopyExitAndOpenLatestWhileKeepingDraft() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["LIFE_UI_TEST_RECOVERY_SIMULATOR"] == nil,
      "Run the app-host recovery fixture on an explicitly selected disposable simulator first.")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    openLocalWorkspace(app)
    openRecord(app, title: "Pending recovery fixture")
    tapWhenReady(app.buttons["Resume draft"])
    XCTAssertEqual(app.textFields["field-title"].value as? String, "Recovered property to keep")
    tapWhenReady(app.buttons["Copy Title"])
    let body = app.buttons["field-body"]
    for _ in 0..<5 where !body.isHittable { scrollRecordFormUp(app) }
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    let source = app.webViews.textViews["Body"]
    XCTAssertEqual(source.value as? String, "Recovered body to keep")
    let copied = typeMarkerThenFinalCharacter(
      source, marker: "CopyZ", previous: "Recovered body to keep")
    app.buttons["Copy Markdown"].tap()
    let retained = typeMarkerThenFinalCharacter(source, marker: "KeepZ", previous: copied)
    // Neither action is preceded by Done or a read after the final keystroke.
    app.buttons["keep-markdown-draft"].tap()
    tapWhenReady(app.navigationBars["Record"].buttons["keep-record-draft"])
    openRecord(app, title: "Pending recovery fixture")
    tapWhenReady(app.buttons["Open saved record"])
    XCTAssertEqual(app.textFields["field-title"].value as? String, "Pending recovery fixture")
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, "Submitted body on disk")
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["Record"].buttons["Cancel"])
    // Paste the copied source into a separate new draft using the actual OS
    // clipboard, then relaunch to verify the original recovery is still there.
    tapWhenReady(app.toolbars.buttons["close"])
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    tapWhenReady(source)
    source.press(forDuration: 1.2)
    tapWhenReady(app.menuItems["Paste"].firstMatch)
    XCTAssertEqual(source.value as? String, copied)
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["New record"].buttons["Cancel"])
    tapWhenReady(app.buttons["Discard changes"])
    app.terminate()
    app.launch()
    openLocalWorkspace(app)
    openRecord(app, title: "Pending recovery fixture")
    tapWhenReady(app.buttons["Resume draft"])
    XCTAssertEqual(app.textFields["field-title"].value as? String, "Recovered property to keep")
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, retained)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "native-pending-recovery-exit"
    shot.lifetime = .keepAlways
    add(shot)
    tapWhenReady(app.buttons["keep-markdown-draft"])
    tapWhenReady(app.navigationBars["Record"].buttons["keep-record-draft"])
  }

  func testAutosaveAndRecoveryKeepBodyAndUnsavedPropertiesAcrossRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    openLocalWorkspace(app)
    let name = "Autosave " + UUID().uuidString.prefix(8)
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    tapWhenReady(app.textFields["field-title"])
    app.textFields["field-title"].typeText(name)
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    openRecord(app, title: String(name))
    let title = app.textFields["field-title"]
    tapWhenReady(title)
    title.typeText(" pending")
    let dirtyTitle = title.value as? String
    let body = app.buttons["field-body"]
    for _ in 0..<5 where !body.isHittable { scrollRecordFormUp(app) }
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    let source = app.webViews.textViews["Body"]
    tapWhenReady(source)
    source.typeText("Synthetic autosave final!")
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout: 10))
    // Termination loses the editor process. Recovery must come from private
    // application state, and the body must already be committed independently.
    app.terminate()
    app.launch()
    openLocalWorkspace(app)
    openRecord(app, title: String(name))
    tapWhenReady(app.buttons["Resume draft"])
    XCTAssertEqual(title.value as? String, dirtyTitle)
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, "Synthetic autosave final!")
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["Record"].buttons["Cancel"])
    tapWhenReady(app.buttons["Discard changes"])
    openRecord(app, title: String(name))
    XCTAssertEqual(title.value as? String, String(name))
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, "Synthetic autosave final!")
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["Record"].buttons["Cancel"])
    tapWhenReady(app.toolbars.buttons["close"])
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    tapWhenReady(title)
    title.typeText("Uncreated recovery fixture")
    for _ in 0..<5 where !body.isHittable { scrollRecordFormUp(app) }
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    tapWhenReady(source)
    source.typeText("Unsaved new source!")
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    app.terminate()
    app.launch()
    openLocalWorkspace(app)
    tapWhenReady(
      app.buttons.matching(identifier: "resume-unsaved-draft").matching(
        NSPredicate(format: "label CONTAINS %@", "Uncreated recovery fixture")
      ).firstMatch)
    tapWhenReady(app.buttons["Resume draft"])
    XCTAssertTrue(app.navigationBars["New record"].waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "Uncreated recovery fixture")
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, "Unsaved new source!")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "native-autosave-recovery"
    shot.lifetime = .keepAlways
    add(shot)
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["New record"].buttons["Cancel"])
    tapWhenReady(app.buttons["Discard changes"])
    XCTAssertFalse(
      app.buttons.matching(
        NSPredicate(
          format: "label BEGINSWITH %@",
          "Uncreated recovery fixture")
      ).firstMatch.exists)
  }

  func testMarkdownSurvivesTenBackgroundAndRotationCycles() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launchArguments = ["--demo"]
    app.launch()
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    let title = app.textFields["field-title"]
    tapWhenReady(title)
    title.typeText("Editor lifecycle fixture")
    let body = app.buttons["field-body"]
    for _ in 0..<5 where !body.isHittable {
      _ = dismissKeyboardTutorial()
      scrollRecordFormUp(app)
    }
    tapWhenReady(body)
    let editor = app.webViews.textViews["Body"]
    tapWhenReady(editor)
    var expected = "Cycles"
    editor.typeText(expected)
    for cycle in 1...10 {
      XCTContext.runActivity(named: "Editor lifecycle cycle \(cycle) of 10") { _ in
        expected = typeMarkerThenFinalCharacter(
          editor, marker: String(format: "%02dz", cycle), previous: expected)
        // Background immediately after the final keystroke, with no save/debounce wait.
        XCUIDevice.shared.press(.home)
        let background = XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
              app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }
          }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 5), .completed)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(
          (editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
          XCUIDevice.shared.orientation = orientation
          let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
              MainActor.assumeIsolated {
                let frame = app.frame
                return frame.width > 0 && frame.height > 0
                  && (orientation == .portrait
                    ? frame.height > frame.width : frame.width > frame.height)
              }
            }, object: app)
          XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
          XCTAssertEqual(
            (editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
        expected = typeMarkerThenFinalCharacter(
          editor, marker: String(format: "%02dv", cycle), previous: expected, refocus: false)
        // Done must collect this final character before returning to the record.
        tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
        tapWhenReady(
          app.navigationBars[cycle == 1 ? "New record" : "Record"].buttons["save-record"])
        let row = app.buttons.matching(
          NSPredicate(format: "label BEGINSWITH %@", "Editor lifecycle fixture")
        ).firstMatch
        tapWhenReady(row)
        tapWhenReady(body)
        tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
        XCTAssertEqual(
          (editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        tapWhenReady(app.webViews.descendants(matching: .any)["Body write"])
      }
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-editor-ten-lifecycle-cycles"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["Record"].buttons["Cancel"])
  }

  private func typeMarkerThenFinalCharacter(
    _ editor: XCUIElement, marker: String, previous: String, refocus: Bool = true
  ) -> String {
    // Rotation can leave the modal window's accessibility frame invalid while
    // its editor visibly retains keyboard focus. Continue real keyboard input
    // instead of asking XCTest to synthesize an unnecessary hit-test tap.
    if refocus || !XCUIApplication().keyboards.firstMatch.exists { tapWhenReady(editor) }
    editor.typeText(marker)
    let entered = (editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    XCTAssertEqual(entered.replacingOccurrences(of: marker, with: ""), previous)
    guard let insertion = entered.range(of: marker) else {
      XCTFail("The editor did not receive the marker")
      return entered
    }
    // Derive the actual insertion position rather than assuming a tap places the
    // caret at the end. No accessibility read occurs after the final character.
    var expected = entered
    expected.insert("!", at: insertion.upperBound)
    editor.typeText("!")
    return expected
  }

  func testNamedReferencesAndSortFiltersUseSavedRecords() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    let title = app.descendants(matching: .any)["field-title"]
    tapWhenReady(title)
    title.typeText("Zulu parity")
    let topic = app.buttons["field-topic"]
    for _ in 0..<8 where !topic.isHittable {
      _ = dismissKeyboardTutorial()
      scrollRecordFormUp(app)
    }
    tapWhenReady(topic)
    XCTAssertTrue(app.navigationBars["Topic"].waitForExistence(timeout: 5))
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[a-f0-9]{32}")).firstMatch
        .exists)
    tapWhenReady(app.buttons["Field notes"])
    XCTAssertTrue(app.navigationBars["New record"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    let related = app.buttons["field-related"]
    for _ in 0..<5 where !related.isHittable {
      _ = dismissKeyboardTutorial()
      scrollRecordFormUp(app)
    }
    tapWhenReady(related)
    tapWhenReady(app.buttons["Field notes"])
    tapWhenReady(app.buttons["Ideas"])
    let pickerShot = XCTAttachment(screenshot: app.screenshot())
    pickerShot.name = "native-named-reference-picker"
    pickerShot.lifetime = .keepAlways
    add(pickerShot)
    tapWhenReady(app.navigationBars["Related topics"].buttons["Done"])
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    let zulu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zulu parity"))
      .firstMatch
    tapWhenReady(zulu)
    for _ in 0..<8 where !related.isHittable {
      _ = dismissKeyboardTutorial()
      scrollRecordFormUp(app)
    }
    XCTAssertTrue(related.waitForExistence(timeout: 5))
    XCTAssertTrue(related.label.contains("Field notes"), related.label)
    XCTAssertTrue(related.label.contains("Ideas"), related.label)
    tapWhenReady(app.navigationBars["Record"].buttons["Cancel"])
    tapWhenReady(app.navigationBars["notes"].buttons["new-record"])
    tapWhenReady(title)
    title.typeText("Alpha parity")
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    tapWhenReady(app.buttons["view-options"])
    tapWhenReady(app.buttons["sort-column"])
    tapWhenReady(app.buttons["Title"])
    tapWhenReady(app.buttons["sort-direction"])
    tapWhenReady(app.buttons["Descending"])
    tapWhenReady(app.buttons["Add filter"])
    tapWhenReady(app.buttons["filter-operation"])
    tapWhenReady(app.buttons["Contains"])
    tapWhenReady(app.textFields["filter-value"])
    app.textFields["filter-value"].typeText("parity")
    tapWhenReady(app.navigationBars["Sort and filter"].buttons["apply-view-options"])
    let alpha = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alpha parity"))
      .firstMatch
    XCTAssertTrue(alpha.waitForExistence(timeout: 5))
    XCTAssertTrue(zulu.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(alpha.frame.height, 0)
    XCTAssertGreaterThan(zulu.frame.height, 0)
    XCTAssertLessThan(zulu.frame.minY, alpha.frame.minY)
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
        .firstMatch.exists)
    let filterShot = XCTAttachment(screenshot: app.screenshot())
    filterShot.name = "native-sorted-filtered-workspace"
    filterShot.lifetime = .keepAlways
    add(filterShot)
    tapWhenReady(app.buttons["view-options"])
    tapWhenReady(app.buttons["Reset sort and filters"])
    tapWhenReady(app.navigationBars["Sort and filter"].buttons["apply-view-options"])
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
        .firstMatch.waitForExistence(timeout: 5))
  }

  func testUsageAndNotificationsThroughTheNativeInterface() throws {
    guard let endpoint = ProcessInfo.processInfo.environment["LIFE_UI_TEST_SERVICES_HUB"] else {
      throw XCTSkip("Set LIFE_UI_TEST_SERVICES_HUB for the synthetic services Worker test")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    tapWhenReady(app.navigationBars["notes"].buttons["Hub connection"])
    tapWhenReady(app.textFields["hub-endpoint"])
    app.textFields["hub-endpoint"].typeText(endpoint)
    tapWhenReady(app.secureTextFields["hub-token"])
    app.secureTextFields["hub-token"].typeText("fixture")
    tapWhenReady(app.buttons["Save and sync"])
    XCTAssertTrue(app.navigationBars["widgets"].waitForExistence(timeout: 15))
    tapWhenReady(app.navigationBars["widgets"].buttons["Hub connection"])
    tapWhenReady(app.buttons["hub-usage"])
    XCTAssertTrue(app.navigationBars["Usage"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Rows read"].firstMatch.waitForExistence(timeout: 10))
    let overviewShot = XCTAttachment(screenshot: app.screenshot())
    overviewShot.name = "native-hub-usage-overview"
    overviewShot.lifetime = .keepAlways
    add(overviewShot)
    let storage = app.staticTexts["Used, Unmeasured"].firstMatch
    for _ in 0..<8 where !storage.isHittable {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    XCTAssertTrue(storage.waitForExistence(timeout: 5))
    let storageShot = XCTAttachment(screenshot: app.screenshot())
    storageShot.name = "native-hub-usage-unmeasured"
    storageShot.lifetime = .keepAlways
    add(storageShot)
    let principal = app.staticTexts["Example device"].firstMatch
    for _ in 0..<5 where !principal.isHittable {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    XCTAssertTrue(principal.waitForExistence(timeout: 5), app.debugDescription)
    let usageShot = XCTAttachment(screenshot: app.screenshot())
    usageShot.name = "native-hub-usage"
    usageShot.lifetime = .keepAlways
    add(usageShot)
    tapWhenReady(app.navigationBars["Usage"].buttons.element(boundBy: 0))
    tapWhenReady(app.buttons["hub-notifications"])
    XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Enable alerts"].waitForExistence(timeout: 5))
    // Reading the feed must not trigger the operating system's permission dialog.
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertTrue(app.staticTexts["205 unread"].waitForExistence(timeout: 10))
    let markOne = app.buttons["mark-read-fixture:205"]
    for _ in 0..<4 where !markOne.isHittable {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    tapWhenReady(markOne)
    for _ in 0..<4 where !app.staticTexts["204 unread"].isHittable {
      _ = dismissPasswordPrompt()
      app.swipeDown()
    }
    XCTAssertTrue(app.staticTexts["204 unread"].waitForExistence(timeout: 10))
    let markAll = app.buttons["mark-all-notifications-read"]
    tapWhenReady(markAll)
    XCTAssertTrue(app.staticTexts["0 unread"].waitForExistence(timeout: 10), app.debugDescription)
    let notificationShot = XCTAttachment(screenshot: app.screenshot())
    notificationShot.name = "native-hub-notifications"
    notificationShot.lifetime = .keepAlways
    add(notificationShot)
    tapWhenReady(app.navigationBars["Notifications"].buttons.element(boundBy: 0))
    let forget = app.buttons["Forget saved connection"]
    for _ in 0..<4 where !forget.isHittable { app.swipeUp() }
    tapWhenReady(forget)
    XCTAssertTrue(app.navigationBars["Hub connection"].waitForNonExistence(timeout: 5))
  }

  func testConnectAndSyncThroughTheNativeInterface() throws {
    guard let endpoint = ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"] else {
      throw XCTSkip("Set LIFE_UI_TEST_HUB for the synthetic Worker test")
    }
    continueAfterFailure = false
    addUIInterruptionMonitor(withDescription: "Password AutoFill") { interruption in
      guard interruption.staticTexts["Save Password?"].exists,
        interruption.buttons["Not Now"].exists
      else { return false }
      interruption.buttons["Not Now"].tap()
      return true
    }
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    let sampleSettings = app.navigationBars["notes"].buttons["Hub connection"]
    tapWhenReady(sampleSettings)
    tapWhenReady(app.textFields["hub-endpoint"])
    app.textFields["hub-endpoint"].typeText(endpoint)
    tapWhenReady(app.secureTextFields["hub-token"])
    app.secureTextFields["hub-token"].typeText("fixture")
    tapWhenReady(app.buttons["Save and sync"])
    XCTAssertTrue(app.navigationBars["widgets"].waitForExistence(timeout: 15))
    // Password AutoFill can offer to save the synthetic token after the sheet closes.
    let passwordPrompt = app.sheets["Save Password?"]
    if passwordPrompt.waitForExistence(timeout: 5) {
      dismissPasswordPrompt()
    }
    let status = app.staticTexts["No local edits waiting to sync."].firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    for _ in 0..<3 {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    _ = dismissPasswordPrompt()
    let scrolledShot = XCTAttachment(screenshot: app.screenshot())
    scrolledShot.name = "native-scrolled-sync-status"
    scrolledShot.lifetime = .keepAlways
    add(scrolledShot)
    XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertGreaterThan(status.frame.height, 0)
    XCTAssertGreaterThan(status.frame.width, 0)
    XCTAssertGreaterThanOrEqual(status.frame.minY, app.navigationBars["widgets"].frame.maxY)
    XCTAssertLessThanOrEqual(status.frame.maxY, app.frame.maxY)
    let create = app.navigationBars["widgets"].buttons["new-record"]
    tapWhenReady(create)
    let title = "Native screen " + UUID().uuidString.prefix(8)
    let field = app.descendants(matching: .any)["field-title"]
    tapWhenReady(field)
    field.typeText(title)
    let quantity = app.descendants(matching: .any)["field-quantity"]
    XCTAssertTrue(quantity.waitForExistence(timeout: 5))
    for _ in 0..<5 where !quantity.isHittable {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    tapWhenReady(quantity)
    quantity.typeText("7")
    XCTAssertEqual(quantity.value as? String, "7", app.debugDescription)
    let save = app.navigationBars["New record"].buttons["save-record"]
    tapWhenReady(save)
    XCTAssertTrue(
      app.staticTexts["1 record waiting to sync."].waitForExistence(timeout: 5),
      app.debugDescription)
    tapWhenReady(app.navigationBars["widgets"].buttons["sync-now"])
    XCTAssertTrue(app.staticTexts["No local edits waiting to sync."].waitForExistence(timeout: 15))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "native-hub-workspace"
    shot.lifetime = .keepAlways
    add(shot)
    let replicaSettings = app.navigationBars["widgets"].buttons["Hub connection"]
    tapWhenReady(replicaSettings)
    let forget = app.buttons["Forget saved connection"]
    tapWhenReady(forget)
    XCTAssertTrue(app.navigationBars["Hub connection"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["widgets"].buttons["sync-now"].waitForNonExistence(timeout: 5))
  }

  func testCreateEditMarkdownTrashAndRestore() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    let create = app.navigationBars["notes"].buttons["new-record"]
    if !create.waitForExistence(timeout: 10) { app.buttons["notes"].tap() }
    tapWhenReady(create)
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    XCTAssertTrue(app.staticTexts["Title is required."].firstMatch.waitForExistence(timeout: 5))
    let title = app.descendants(matching: .any)["field-title"]
    tapWhenReady(title)
    title.typeText("Synthetic UI note")
    let body = app.buttons["field-body"]
    for _ in 0..<5 where !body.isHittable {
      _ = dismissPasswordPrompt()
      scrollRecordFormUp(app)
    }
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    let source = app.webViews.textViews["Body"]
    tapWhenReady(source)
    source.typeText("# Markdown source\n\nA synthetic paragraph.")
    let sourceShot = XCTAttachment(screenshot: app.screenshot())
    sourceShot.name = "native-markdown-editor"
    sourceShot.lifetime = .keepAlways
    add(sourceShot)
    // Done reads the live snapshot without waiting for a debounce after typing.
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic UI note"))
      .firstMatch
    tapWhenReady(row)
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertEqual(source.value as? String, "# Markdown source\n\nA synthetic paragraph.")
    tapWhenReady(app.webViews.descendants(matching: .any)["Body write"])
    let rich = app.webViews.textViews["Body"]
    tapWhenReady(rich)
    rich.typeText(" Final rich keystroke.")
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(app.navigationBars["Record"].buttons["save-record"])
    tapWhenReady(row)
    tapWhenReady(body)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body source"])
    XCTAssertTrue(
      (source.value as? String)?.contains("Final rich keystroke.") == true, app.debugDescription)
    tapWhenReady(app.webViews.descendants(matching: .any)["Body write"])
    XCTAssertTrue(app.webViews.buttons["Heading 1"].waitForExistence(timeout: 5))
    let richShot = XCTAttachment(screenshot: app.screenshot())
    richShot.name = "native-shared-markdown-editor"
    richShot.lifetime = .keepAlways
    add(richShot)
    tapWhenReady(app.navigationBars["Body"].buttons["finish-markdown"])
    tapWhenReady(title)
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    title.typeText(" revised")
    XCTAssertEqual(title.value as? String, "Synthetic UI note revised", app.debugDescription)
    tapWhenReady(app.navigationBars["Record"].buttons["save-record"])
    let edited = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Synthetic UI note revised")
    ).firstMatch
    tapWhenReady(edited)
    let trash = app.buttons["trash-record"]
    for _ in 0..<5 where !trash.isHittable { app.swipeUp() }
    tapWhenReady(trash)
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    XCTAssertTrue(edited.waitForNonExistence(timeout: 5))
    tapWhenReady(app.navigationBars["notes"].buttons["toggle-trash"])
    tapWhenReady(edited)
    let restore = app.buttons["trash-record"]
    for _ in 0..<5 where !restore.isHittable { app.swipeUp() }
    tapWhenReady(restore)
    XCTAssertTrue(app.buttons["toggle-trash"].waitForExistence(timeout: 5))
    tapWhenReady(app.navigationBars["notes"].buttons["toggle-trash"])
    XCTAssertTrue(edited.waitForExistence(timeout: 5))
    let listShot = XCTAttachment(screenshot: app.screenshot())
    listShot.name = "native-local-workspace"
    listShot.lifetime = .keepAlways
    add(listShot)
  }

  private func tapWhenReady(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          if self.dismissPasswordPrompt() || self.dismissKeyboardTutorial() { return false }
          guard element.exists else { return false }
          let frame = element.frame
          return frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
            && element.isHittable
        }
      }, object: element)
    let result = XCTWaiter.wait(for: [ready], timeout: 10)
    if result != .completed {
      let screenshot = XCTAttachment(screenshot: XCUIApplication().screenshot())
      screenshot.name = "unreachable-control"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
    XCTAssertEqual(
      result, .completed, XCUIApplication().debugDescription,
      file: file, line: line)
    element.tap()
  }

  private func openRecord(_ app: XCUIApplication, title: String) {
    let search = app.searchFields.firstMatch
    if search.value as? String != title {
      tapWhenReady(search)
      let clear = search.buttons["Clear text"]
      if clear.exists { clear.tap() }
      search.typeText(title)
    }
    tapWhenReady(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch)
  }

  private func openLocalWorkspace(_ app: XCUIApplication) {
    let open = app.buttons["open-local"]
    if !open.waitForExistence(timeout: 3) {
      // A preceding failed network test may leave a saved synthetic connection.
      // Navigate through the supported UI instead of assuming the welcome screen.
      tapWhenReady(app.navigationBars.buttons["BackButton"].firstMatch)
      tapWhenReady(app.buttons["Close workspace"])
    }
    tapWhenReady(open)
  }

  private func scrollRecordFormUp(_ app: XCUIApplication) {
    let form = app.collectionViews["record-form"]
    // Drag the Form's gutter without scrolling an embedded source field.
    form.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2)))
  }

  @discardableResult
  private func dismissKeyboardTutorial() -> Bool {
    let app = XCUIApplication()
    let tutorial = app.staticTexts.matching(
      NSPredicate(
        format: "label BEGINSWITH %@", "Speed up your typing by sliding your finger")
    ).firstMatch
    let button = app.buttons["Continue"]
    guard tutorial.exists, button.isHittable else { return false }
    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(tutorial.waitForNonExistence(timeout: 5))
    return true
  }

  @discardableResult
  private func dismissPasswordPrompt() -> Bool {
    let prompt = XCUIApplication().sheets["Save Password?"]
    guard prompt.exists, prompt.buttons["Not Now"].isHittable else { return false }
    // This button belongs to the remote Password AutoFill process. A coordinate
    // anchored to the app sends the event to the wrong process on iOS.
    prompt.buttons["Not Now"].tap()
    // The remote system sheet can still be visibly fading after five seconds
    // under simulator load. Wait for its actual dismissal before touching the app.
    XCTAssertTrue(prompt.waitForNonExistence(timeout: 15))
    return true
  }
}
