import XCTest

/// Create-in-place from ref/multi_ref pickers on a synthetic people/companies/meetings
/// database opened through the supported external-file picker (README, "reference create").
@MainActor
final class ReferenceCreateUITests: XCTestCase {
  func testPickersCreateRecordsInPlaceAndHandRequiredFieldsToTheEditor() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["IRIS_TEST_CATALOG_CLEAN_HOST"] == "1",
      "Use a disposable clean host; normal startup must never inspect an enrolled user's credentials."
    )
    let path = ProcessInfo.processInfo.environment["IRIS_TEST_REFERENCE_CREATE_DATABASE"]
    try XCTSkipUnless(path != nil, "Prepare the synthetic reference-create fixture first.")
    let file = URL(fileURLWithPath: try XCTUnwrap(path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 3) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    // The clean runner can retain the preceding test's synthetic file selection.
    let previous = app.buttons["Close workspace"]
    if previous.waitForExistence(timeout: 3) { previous.click() }
    // Never replace the app's local replica: open the external fixture file.
    let open = app.buttons["Open a local database…"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.typeText(file.path)
    location.typeKey(.return, modifierFlags: [])
    let confirmOpen = app.sheets.buttons["Open"].firstMatch
    XCTAssertTrue(confirmOpen.waitForExistence(timeout: 5))
    confirmOpen.click()
    click(app.buttons["sidebar-table-meetings"])
    click(app.buttons["Open Planning sync"])

    // An exact name offers no creation; new text creates and selects the record.
    click(app.buttons["field-host"])
    search("Ada Lovelace", app: app)
    XCTAssertTrue(app.buttons["Ada Lovelace"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["create-reference-host"].exists)
    search("Katherine Johnson", app: app)
    capture(app, "mac-offer")
    click(app.buttons["create-reference-host"])
    XCTAssertTrue(label("host", app: app).contains("Katherine Johnson"))

    // multi_ref appends after the existing attendee and keeps the picker open.
    click(app.buttons["field-attendees"])
    search("Dorothy Vaughan", app: app)
    click(app.buttons["create-reference-attendees"])
    let added = app.buttons["Remove Dorothy Vaughan"]
    XCTAssertTrue(added.waitForExistence(timeout: 10))
    XCTAssertLessThan(app.buttons["Remove Grace Hopper"].frame.minY, added.frame.minY)
    capture(app, "mac-created-multi")
    // The sheet's native back control returns to the record form.
    click(app.sheets.buttons["Back"].firstMatch)
    XCTAssertTrue(app.buttons["field-attendees"].waitForExistence(timeout: 10))
    XCTAssertTrue(label("attendees", app: app).contains("Dorothy Vaughan"))

    // A required field without a default opens the editor; Cancel keeps the relation.
    XCTAssertTrue(label("company", app: app).contains("Acme"))
    click(app.buttons["field-company"])
    search("Globex", app: app)
    click(app.buttons["create-reference-company"])
    click(app.buttons["create-reference-cancel"])
    XCTAssertTrue(app.buttons["create-reference-save"].waitForNonExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Remove Globex"].exists)
    search("Initech", app: app)
    click(app.buttons["create-reference-company"])
    let name = app.textFields["field-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    XCTAssertEqual(name.value as? String, "Initech")
    capture(app, "mac-handoff")
    click(app.buttons["create-reference-save"])
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "domain is required",
          "domain is required")
      ).firstMatch.waitForExistence(timeout: 10))
    capture(app, "mac-handoff-validation")
    let domain = app.textFields["field-domain"]
    click(domain)
    domain.typeText("initech.example")
    click(app.buttons["create-reference-save"])
    XCTAssertTrue(label("company", app: app).contains("Initech"))
    click(app.buttons["save-record"])
    capture(app, "mac-saved")
  }

  private func search(_ text: String, app: XCUIApplication) {
    // The picker's own field, not the workspace window's table search.
    let field = app.searchFields.matching(
      NSPredicate(format: "placeholderValue == %@", "Search records")
    ).firstMatch
    click(field)
    field.typeKey("a", modifierFlags: .command)
    field.typeText(text)
  }

  private func label(_ column: String, app: XCUIApplication) -> String {
    let field = app.buttons["field-\(column)"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    return field.label
  }

  private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 15), file: file, line: line)
    element.click()
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
