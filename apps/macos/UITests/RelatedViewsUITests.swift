import XCTest

@MainActor
final class RelatedViewsUITests: XCTestCase {
  func testMainAndRelatedPreferencesStayIndependentThroughUserControls() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    let views = app.buttons["saved-views"]
    XCTAssertTrue(views.waitForExistence(timeout: 20))
    views.click()
    let name = app.textFields["saved-view-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    func save(_ title: String) {
      name.click()
      name.typeKey("a", modifierFlags: .command)
      name.typeText(title)
      app.buttons["save-view-copy"].click()
      XCTAssertTrue(app.staticTexts["Saved on this device."].waitForExistence(timeout: 10))
    }
    save("Everyday fixture")
    app.buttons["set-default-view"].click()
    XCTAssertTrue(
      app.staticTexts["Default view saved. It applies when opening this table."].waitForExistence(
        timeout: 10))
    save("Related fixture")
    app.buttons["set-related-view"].click()
    XCTAssertTrue(app.staticTexts["Related-record view saved."].waitForExistence(timeout: 10))
    XCTAssertTrue(shows(app, "default-view-name", "Everyday fixture"))
    XCTAssertTrue(shows(app, "related-view-name", "Related fixture"))
    app.buttons["undo-saved-view"].click()
    XCTAssertTrue(app.staticTexts["Saved change undone."].waitForExistence(timeout: 10))
    XCTAssertTrue(shows(app, "related-view-name", "All live links"))
    XCTAssertTrue(shows(app, "default-view-name", "Everyday fixture"))
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "independent-related-view"
    image.lifetime = .keepAlways
    add(image)
  }

  /// macOS exposes SwiftUI Text content as the accessibility value; its label is empty.
  private func shows(_ app: XCUIApplication, _ id: String, _ text: String) -> Bool {
    let element = app.staticTexts[id]
    let shown = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", text), object: element)
    return XCTWaiter().wait(for: [shown], timeout: 10) == .completed
  }
}
