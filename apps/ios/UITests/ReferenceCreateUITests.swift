import XCTest

/// Create-in-place from ref/multi_ref pickers on a synthetic people/companies/meetings
/// workspace seeded as the private simulator's local workspace (README, "reference create").
@MainActor
final class ReferenceCreateUITests: XCTestCase {
  func testPickersCreateRecordsInPlaceAndHandRequiredFieldsToTheEditor() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["LIFE_UI_TEST_REFERENCE_CREATE_SIMULATOR"] == nil,
      "Requires the reference-create fixture on an explicitly selected private simulator")
    XCTAssertEqual(
      environment["LIFE_UI_TEST_REFERENCE_CREATE_SIMULATOR"], environment["SIMULATOR_UDID"])
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    tap(app.buttons["open-local"])
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeText("Planning sync")
    tap(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quick-find-result-meetings-'"))
        .firstMatch)
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))

    // An exact name offers no creation; new text creates and selects the record.
    pick("host", app: app)
    search("Ada Lovelace", app: app)
    XCTAssertTrue(app.buttons["Ada Lovelace"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["create-reference-host"].exists)
    search("Katherine Johnson", app: app)
    let createHost = app.buttons["create-reference-host"]
    XCTAssertTrue(createHost.waitForExistence(timeout: 10))
    capture(app, "ios-offer")
    tap(createHost)
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))
    XCTAssertTrue(label("host", app: app).contains("Katherine Johnson"))

    // multi_ref appends after the existing attendee and keeps the picker open.
    pick("attendees", app: app)
    search("Dorothy Vaughan", app: app)
    tap(app.buttons["create-reference-attendees"])
    let selected = app.buttons["Remove Dorothy Vaughan"]
    XCTAssertTrue(selected.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Remove Grace Hopper"].exists)
    XCTAssertLessThan(app.buttons["Remove Grace Hopper"].frame.minY, selected.frame.minY)
    capture(app, "ios-created-multi")
    tap(app.navigationBars.buttons["Done"])

    // A required field without a default opens the editor; Cancel keeps the relation.
    pick("company", app: app)
    search("Globex", app: app)
    tap(app.buttons["create-reference-company"])
    XCTAssertTrue(app.navigationBars["New record"].waitForExistence(timeout: 10))
    tap(app.buttons["create-reference-cancel"])
    XCTAssertTrue(app.navigationBars["New record"].waitForNonExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Remove Globex"].exists)
    search("Initech", app: app)
    tap(app.buttons["create-reference-company"])
    XCTAssertTrue(app.navigationBars["New record"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["field-name"].value as? String, "Initech")
    capture(app, "ios-handoff")
    tap(app.buttons["create-reference-save"])
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'domain is required'")).firstMatch
        .waitForExistence(timeout: 10))
    capture(app, "ios-handoff-validation")
    let domain = app.textFields["field-domain"]
    tap(domain)
    domain.typeText("initech.example")
    tap(app.buttons["create-reference-save"])
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))
    XCTAssertTrue(label("company", app: app).contains("Initech"))
    tap(app.buttons["save-record"])
    capture(app, "ios-saved")
  }

  private func pick(_ column: String, app: XCUIApplication) {
    let field = app.buttons["field-\(column)"]
    for _ in 0..<6 where !(field.exists && field.isHittable) {
      app.collectionViews["record-form"].swipeUp()
    }
    tap(field)
  }

  private func search(_ text: String, app: XCUIApplication) {
    let field = app.searchFields.firstMatch
    tap(field)
    if let current = field.value as? String, !current.isEmpty, current != "Search records" {
      field.buttons["Clear text"].tap()
    }
    field.typeText(text)
  }

  private func label(_ column: String, app: XCUIApplication) -> String {
    let field = app.buttons["field-\(column)"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    return field.label
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 15), file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { element.isHittable } },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
