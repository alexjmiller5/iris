import UIKit
import XCTest

@MainActor
final class TypedFieldsUITests: XCTestCase {
  func testChoicesRetainUnknownValuesUntilExplicitRepairAndSave() throws {
    let app = try openFixture("choices")
    defer { app.terminate() }
    let removeUnknown = app.buttons["remove-choice-tags-Unknown"]
    reveal(removeUnknown, in: app)
    XCTAssertTrue(app.buttons["remove-choice-tags-Alpha"].exists)
    tap(app.buttons["add-choice-tags"])
    tap(app.buttons["Beta"])
    tap(app.buttons["remove-choice-tags-Alpha"])
    XCTAssertTrue(removeUnknown.exists)
    let dynamic = app.buttons["field-dynamic"]
    reveal(dynamic, in: app)
    tap(dynamic)
    tap(app.buttons["Dynamic two"])
    let spelling = app.buttons["field-spelling"]
    reveal(spelling, in: app)
    tap(spelling)
    tap(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Second spelling")).firstMatch)
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not options for tags"))
        .firstMatch.waitForExistence(timeout: 5))
    reveal(removeUnknown, in: app, down: true)
    tap(removeUnknown)
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: "choices")
    reveal(app.buttons["remove-choice-tags-Beta"], in: app)
    XCTAssertFalse(removeUnknown.exists)
    XCTAssertTrue(app.buttons["remove-choice-tags-Beta"].exists)
    XCTAssertFalse(app.buttons["remove-choice-tags-Alpha"].exists)
    reveal(dynamic, in: app)
    XCTAssertTrue(
      dynamic.label.contains("Dynamic two")
        || (dynamic.value as? String)?.contains("Dynamic two") == true)
    reveal(spelling, in: app)
    XCTAssertTrue(
      spelling.label.contains("Second spelling")
        || (spelling.value as? String)?.contains("Second spelling") == true)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-typed-choices-reopened"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testDateControlsPreserveSourceUntilExplicitClear() throws {
    let app = try openFixture("dates")
    defer { app.terminate() }
    let picker = app.datePickers["date-picker-day"]
    reveal(picker, in: app)
    XCTAssertEqual(app.textFields["field-day"].value as? String, "2024-02-29")
    let moment = app.textFields["field-moment"]
    reveal(moment, in: app)
    XCTAssertEqual(moment.value as? String, "2024-02-29T23:04:05.123Z")
    XCTAssertTrue(app.datePickers["date-picker-moment"].exists)
    let clear = app.buttons["clear-date-day"]
    reveal(clear, in: app, down: true)
    tap(clear)
    let choose = app.buttons["choose-date-day"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    expectEmpty(app.textFields["field-day"])
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: "dates")
    reveal(choose, in: app)
    expectEmpty(app.textFields["field-day"])
    reveal(moment, in: app)
    XCTAssertEqual(moment.value as? String, "2024-02-29T23:04:05.123Z")
    let link = app.buttons["open-link-website"]
    reveal(link, in: app)
    XCTAssertTrue(link.isEnabled)
    reveal(choose, in: app, down: true)
    tap(choose)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    XCTAssertEqual(app.textFields["field-day"].value as? String, today)
    XCTAssertTrue(app.datePickers["date-picker-day"].exists)
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: "dates")
    reveal(app.datePickers["date-picker-day"], in: app)
    XCTAssertEqual(app.textFields["field-day"].value as? String, today)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-typed-date-today-reopened"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func expectEmpty(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
  {
    let value = field.value as? String
    XCTAssertNotNil(value, file: file, line: line)
    // UIKit exposes the placeholder as the accessibility value of an empty field.
    XCTAssertTrue(value == "" || value == field.placeholderValue, file: file, line: line)
  }

  private func openFixture(_ record: String) throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["LIFE_UI_TEST_FIELDS_SIMULATOR"] == nil,
      "Requires the typed-fields fixture on an explicitly selected private simulator")
    guard let expected = environment["LIFE_UI_TEST_FIELDS_SIMULATOR"], !expected.isEmpty,
      expected == environment["SIMULATOR_UDID"]
    else {
      throw NSError(
        domain: "TypedFieldsUITests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The selected fixture simulator does not match."])
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: record)
    return app
  }

  private func findRecord(_ app: XCUIApplication, record: String) {
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeText(record == "choices" ? "Choice field notebook" : "Date field notebook")
    tap(app.buttons["quick-find-result-field_examples-typed-\(record)"])
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
  }

  private func reveal(
    _ element: XCUIElement, in app: XCUIApplication, down: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let form = app.collectionViews["record-form"]
    func visibleArea() -> CGRect {
      var area = form.frame.intersection(app.frame)
      let top = max(area.minY, app.navigationBars["Record"].frame.maxY)
      let keyboard = app.keyboards.firstMatch
      let bottom = min(area.maxY - 34, keyboard.exists ? keyboard.frame.minY - 52 : area.maxY)
      area.origin.y = top
      area.size.height = max(0, bottom - top)
      return area
    }
    func visible() -> Bool {
      guard element.exists, element.isHittable, element.frame.height > 0 else { return false }
      return visibleArea().contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }
    for _ in 0..<14 {
      if visible() { break }
      let area = visibleArea()
      let moveDown =
        element.exists && element.frame.height > 0
        ? element.frame.midY < area.minY : down
      let distance = min(180, area.height / 2)
      let start = CGPoint(x: area.maxX - 12, y: moveDown ? area.minY + 25 : area.maxY - 25)
      let end = CGPoint(x: start.x, y: start.y + (moveDown ? distance : -distance))
      let origin = app.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(
        forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    XCTAssertTrue(visible(), app.debugDescription, file: file, line: line)
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.isHittable }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }
}
