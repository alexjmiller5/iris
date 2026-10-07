import XCTest

@MainActor
final class CatalogEditorUITests: XCTestCase {
  func testCatalogEditRetainsInvalidDraftAndRefreshesRecordMetadata() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_CLEAN_HOST"] == "1",
      "Use the allocated clean CI host.")
    let app = XCUIApplication()
    // The sample is a separate memory-backed workspace and skips resumeConnection.
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 3) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let edit = app.buttons["edit-catalog"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.click()
    let entry = app.descendants(matching: .any)["catalog-entry"].firstMatch
    let entryAppeared = entry.waitForExistence(timeout: 5)
    if !entryAppeared {
      let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      screen.name = "catalog-editor-missing-entry-screen"
      screen.lifetime = .keepAlways
      add(screen)
    }
    XCTAssertTrue(entryAppeared, app.debugDescription)
    XCTAssertTrue(entry.isHittable)
    entry.click()
    app.menuItems["title"].click()
    let label = app.textFields["catalog-label"]
    replace(label, with: "Display title")
    let pattern = app.textFields["catalog-pattern"]
    for _ in 0..<4 where !pattern.isHittable {
      app.scrollViews["catalog-form"].scroll(byDeltaX: 0, deltaY: -250)
    }
    XCTAssertTrue(pattern.isHittable)
    replace(pattern, with: "[")
    app.buttons["catalog-save"].click()
    XCTAssertTrue(app.staticTexts["catalog-error"].waitForExistence(timeout: 5))
    XCTAssertEqual(label.value as? String, "Display title")
    XCTAssertEqual(pattern.value as? String, "[")
    replace(pattern, with: "")
    app.buttons["catalog-save"].click()
    XCTAssertTrue(app.staticTexts["catalog-receipt"].waitForExistence(timeout: 5))
    app.buttons["Close"].click()
    let record = app.buttons["Open A place to start"]
    XCTAssertTrue(record.waitForExistence(timeout: 5))
    record.click()
    XCTAssertTrue(app.textFields["field-title"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Display title"].exists)
    XCTAssertEqual(app.textFields["field-title"].value as? String, "A place to start")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "catalog-edit-record-metadata"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func replace(_ field: XCUIElement, with value: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeKey(.delete, modifierFlags: [])
    if !value.isEmpty { field.typeText(value) }
  }
}
