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
    let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
    start.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
    let search = springboard.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.typeText("A place to start")
    let result = springboard.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "A place to start")
    ).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 20))
    keep(springboard, "spotlight-title-result")
    result.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let open = app.buttons["open-pending-link"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    keep(app, "spotlight-link-banner")
    let ready = NSPredicate(format: "isEnabled == true")
    expectation(for: ready, evaluatedWith: open)
    waitForExpectations(timeout: 15)
    open.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, "A place to start")
    keep(app, "spotlight-row-opened")
  }

  func testShareSheetPreparesADraftThatOpensUnsaved() throws {
    let app = try application()
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.open(URL(string: "https://example.com/life-ui-share-check")!)
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
    let share = safari.buttons["ShareButton"].exists ? safari.buttons["ShareButton"] : safari.buttons["Share"]
    XCTAssertTrue(share.waitForExistence(timeout: 20))
    share.tap()
    let target = safari.cells.matching(NSPredicate(format: "label == %@", "Life UI")).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 15))
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
