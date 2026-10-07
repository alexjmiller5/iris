import XCTest

@MainActor
final class HumanUndoUITests: XCTestCase {
  func testCommandZAndButtonUndoHumanSavesWithoutStealingTyping() throws {
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
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 20))
    func open(_ title: String) {
      let row = grid.buttons["Open \(title)"]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      row.click()
      XCTAssertTrue(app.sheets.textFields["field-title"].waitForExistence(timeout: 5))
    }
    func save(_ title: String) {
      let field = app.sheets.textFields["field-title"]
      field.click()
      field.typeKey("a", modifierFlags: .command)
      field.typeText(title)
      app.buttons["save-record"].click()
      XCTAssertTrue(grid.buttons["Open \(title)"].waitForExistence(timeout: 10))
    }
    open("A place to start")
    save("Human first save")
    open("Human first save")
    save("Human second save")
    grid.click()
    app.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(grid.buttons["Open Human first save"].waitForExistence(timeout: 10))
    app.buttons["undo-saved-change"].click()
    XCTAssertTrue(grid.buttons["Open A place to start"].waitForExistence(timeout: 10))
    open("A place to start")
    let field = app.sheets.textFields["field-title"]
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Typing only")
    field.typeKey("z", modifierFlags: .command)
    let restored = NSPredicate(format: "value == %@", "A place to start")
    expectation(for: restored, evaluatedWith: field)
    waitForExpectations(timeout: 5)
    app.buttons["Cancel"].firstMatch.click()
    XCTAssertTrue(grid.buttons["Open A place to start"].waitForExistence(timeout: 10))
  }
}
