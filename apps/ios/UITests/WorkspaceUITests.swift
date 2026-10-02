import XCTest

@MainActor
final class WorkspaceUITests: XCTestCase {
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
    let body = app.textViews["field-body"]
    for _ in 0..<5 where !body.isHittable {
      _ = dismissPasswordPrompt()
      app.swipeUp()
    }
    tapWhenReady(body)
    body.typeText("# Markdown source\n\nA synthetic paragraph.")
    let sourceShot = XCTAttachment(screenshot: app.screenshot())
    sourceShot.name = "native-markdown-editor"
    sourceShot.lifetime = .keepAlways
    add(sourceShot)
    tapWhenReady(app.navigationBars["New record"].buttons["save-record"])
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic UI note"))
      .firstMatch
    tapWhenReady(row)
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    XCTAssertEqual(body.value as? String, "# Markdown source\n\nA synthetic paragraph.")
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
          if self.dismissPasswordPrompt() { return false }
          return element.exists && element.isHittable
        }
      }, object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [ready], timeout: 10), .completed, element.debugDescription,
      file: file, line: line)
    element.tap()
  }

  @discardableResult
  private func dismissPasswordPrompt() -> Bool {
    let prompt = XCUIApplication().sheets["Save Password?"]
    guard prompt.exists, prompt.buttons["Not Now"].isHittable else { return false }
    prompt.buttons["Not Now"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
    return true
  }
}
