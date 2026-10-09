import XCTest

/// System entry points against the app's own local workspace on an explicitly
/// owned simulator, after `WidgetRolloverUIFixtureTests` enabled the synthetic
/// sources. Every path ends in an ordinary pending link or draft; nothing saves.
@MainActor final class NativeIntegrationsUITests: XCTestCase {
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  private func application() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard let selected = environment["LIFE_UI_TEST_WIDGET_SIMULATOR"],
      selected == environment["SIMULATOR_UDID"]
    else { throw XCTSkip("Select this exact disposable SIMULATOR_UDID for integration tests.") }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    return app
  }

  private func openWorkspace(_ app: XCUIApplication) {
    if app.buttons["open-local"].waitForExistence(timeout: 5) { app.buttons["open-local"].tap() }
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
  }

  /// Hierarchy text for diagnosing system UI that changes between OS releases.
  private func require(_ element: XCUIElement, in app: XCUIApplication, _ timeout: TimeInterval) {
    guard !element.waitForExistence(timeout: timeout) else { return }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "hierarchy"
    tree.lifetime = .keepAlways
    add(tree)
    keep(app, "missing-element")
    XCTFail("Missing \(element)")
  }

  private func keep(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testDailySectionSitsAboveTablesAndOpensItsRow() throws {
    let app = try application()
    app.launch()
    openWorkspace(app)
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    if back.waitForExistence(timeout: 5) { back.tap() }
    let section = app.buttons["daily-section"]
    XCTAssertTrue(section.waitForExistence(timeout: 15))
    if ProcessInfo.processInfo.environment["LIFE_UI_TEST_DAILY_AFTER_BOUNDARY"] != nil {
      // Rows saved before the configured 03:00 boundary roll out of Today with the app closed.
      XCTAssertTrue(app.staticTexts["No matching records"].waitForExistence(timeout: 15))
      XCTAssertFalse(app.buttons["daily-row"].exists)
      keep(app, "daily-section-after-boundary")
      return
    }
    let row = app.buttons["daily-row"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    let table = app.buttons["sidebar-table-notes"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    XCTAssertLessThan(row.frame.maxY, table.frame.minY)
    keep(app, "daily-section-above-tables")
    let title = row.label
    row.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, title)
    keep(app, "daily-row-opened")
  }

  func testSpotlightTitleOpensItsRowThroughTheLinkBanner() throws {
    let app = try application()
    XCUIDevice.shared.press(.home)
    let pill = springboard.otherElements["spotlight-pill"].firstMatch
    if pill.waitForExistence(timeout: 5) { pill.tap() } else { springboard.swipeDown() }
    // Spotlight's field and results live in their own process on current iOS.
    let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
    let search = spotlight.textFields["SpotlightSearchField"]
    require(search, in: spotlight, 10)
    search.tap()
    // A unique synthetic title saved by the Quick Add acceptance run.
    let title = "Quick Add fixture saved"
    search.typeText(title + "\n")
    // Only Life UI's own Core Spotlight item (under the app's section), never a web
    // suggestion with the same text.
    let header = spotlight.otherElements.matching(
      NSPredicate(format: "identifier BEGINSWITH 'Identifier:SectionHeader' AND identifier ENDSWITH ',Title:Life UI'")
    ).firstMatch
    require(header, in: spotlight, 20)
    let section = header.identifier.components(separatedBy: ",").first { $0.hasPrefix("Section:") } ?? ""
    let result = spotlight.cells.matching(
      NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS[c] %@", "ResultCell,\(section),", title)
    ).firstMatch
    require(result, in: spotlight, 20)
    keep(spotlight, "spotlight-title-result")
    result.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let open = app.buttons["open-pending-link"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    keep(app, "spotlight-link-banner")
    // A system launch can land on the welcome screen; the link waits for the workspace.
    if app.buttons["open-local"].exists { app.buttons["open-local"].tap() }
    let ready = NSPredicate(format: "isEnabled == true")
    expectation(for: ready, evaluatedWith: open)
    waitForExpectations(timeout: 15)
    open.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, title)
    keep(app, "spotlight-row-opened")
  }

  /// Gallery discovery, Home Screen placement and a widget tap into the app.
  func testGalleryAddsATodayWidgetThatOpensTheApp() throws {
    let app = try application()
    XCUIDevice.shared.press(.home)
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
    let edit = springboard.buttons["Edit"]
    if edit.waitForExistence(timeout: 8) { edit.tap() }
    let add = springboard.buttons["Add Widget"]
    require(add, in: springboard, 10)
    add.tap()
    let search = springboard.searchFields.firstMatch
    require(search, in: springboard, 15)
    search.tap()
    search.typeText("Life UI")
    let entry = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Life UI'")
    ).element(boundBy: 1)
    require(entry, in: springboard, 15)
    keep(springboard, "widget-gallery-search")
    entry.tap()
    let addWidget = springboard.buttons.matching(NSPredicate(format: "label == 'Add Widget'")).firstMatch
    require(addWidget, in: springboard, 15)
    keep(springboard, "widget-gallery-life-ui")
    addWidget.tap()
    let done = springboard.buttons["Done"]
    if done.waitForExistence(timeout: 10) { done.tap() }
    keep(springboard, "home-screen-widget")
    let widget = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "identifier CONTAINS[c] 'LifeUI' OR label CONTAINS 'Records' OR label CONTAINS 'Synthetic'")
    ).firstMatch
    require(widget, in: springboard, 15)
    widget.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    keep(app, "widget-opened-app")
  }

  func testShareSheetPreparesADraftThatOpensUnsaved() throws {
    let app = try application()
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.open(URL(string: "https://example.com/life-ui-share-check")!)
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
    _ = safari.webViews.firstMatch.waitForExistence(timeout: 20)
    let share = safari.buttons.matching(
      NSPredicate(format: "identifier == 'ShareButton' OR label == 'Share'")
    ).firstMatch
    if !share.waitForExistence(timeout: 5) {
      // Newer Safari keeps Share inside the page menu.
      let menu = safari.buttons.matching(
        NSPredicate(format: "label IN {'More', 'Page Menu', 'Show Page Menu'}")
      ).firstMatch
      require(menu, in: safari, 10)
      menu.tap()
    }
    require(share, in: safari, 10)
    share.tap()
    let target = safari.descendants(matching: .any)["Life UI"].firstMatch
    require(target, in: safari, 15)
    target.tap()
    let prepare = safari.buttons["share-prepare"]
    XCTAssertTrue(prepare.waitForExistence(timeout: 20))
    keep(safari, "share-sheet-draft-form")
    prepare.tap()
    XCTAssertTrue(
      safari.staticTexts["Draft ready. Open Life UI to review and save it."].waitForExistence(timeout: 10))
    keep(safari, "share-sheet-draft-ready")
    safari.buttons["Done"].tap()
    app.launch()
    openWorkspace(app)
    let pending = app.buttons["open-quick-add"]
    XCTAssertTrue(pending.waitForExistence(timeout: 15))
    pending.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, "https://example.com/life-ui-share-check")
    keep(app, "share-draft-in-app")
  }
}
