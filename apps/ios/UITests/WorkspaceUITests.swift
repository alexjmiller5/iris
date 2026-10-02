import XCTest

@MainActor
final class WorkspaceUITests: XCTestCase {
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
          return element.exists && element.isHittable
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
    XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
    return true
  }
}
