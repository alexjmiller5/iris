import XCTest

@MainActor
final class InlineMarkdownUITests: XCTestCase {
  func testContentCellUsesRichMarkdownAndSavesTheFinalInput() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let header = grid.buttons.matching(NSPredicate(format: "title == %@", "Body")).firstMatch
    let title = grid.staticTexts.matching(NSPredicate(format: "value == %@", "A place to start"))
      .firstMatch
    XCTAssertTrue(header.exists)
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 0, dy: title.frame.midY - header.frame.midY)).doubleClick()
    let rich = grid.webViews.textViews["Body"]
    XCTAssertTrue(
      rich.waitForExistence(timeout: 10), "Content must edit as rich Markdown inside the table")
    XCTAssertEqual(app.sheets.count, 0)
    rich.click()
    rich.typeKey("a", modifierFlags: .command)
    rich.typeText("# Inline heading\n\n- First item")
    XCTAssertLessThanOrEqual(grid.buttons["inline-save"].frame.maxX, grid.frame.maxX)
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "inline-markdown-cell"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    grid.buttons["inline-save"].click()
    XCTAssertTrue(rich.waitForNonExistence(timeout: 5))
    let preview = grid.staticTexts.matching(
      NSPredicate(format: "value CONTAINS %@", "Inline heading")
    ).firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    XCTAssertFalse(
      (preview.value as? String ?? "").contains("# Inline heading"),
      "Table preview interprets Markdown")
    grid.buttons["Open A place to start"].click()
    let body = app.sheets.descendants(matching: .any).matching(identifier: "field-body").firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    XCTAssertTrue(app.sheets.webViews.textViews["Body"].waitForExistence(timeout: 10))
    let options = app.webViews.descendants(matching: .any)["Body options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.click()
    app.webViews.descendants(matching: .any)["Body source"].click()
    let source = app.webViews.textViews["Body"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    let stored = source.value as? String ?? ""
    XCTAssertTrue(stored.contains("# Inline heading"))
    XCTAssertTrue(stored.contains("First item"))
    XCTAssertTrue(stored.contains("- First item") || stored.contains("* First item"))
  }
}
