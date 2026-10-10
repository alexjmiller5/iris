import UIKit
import XCTest

@MainActor
final class TypedFieldsUITests: XCTestCase {
  func testDateUsesPickerAndImageUsesPreviewBeforeSource() throws {
    let app = try openFixture("choices")
    defer { app.terminate() }
    let day = app.datePickers["date-picker-day"]
    reveal(day, in: app)
    XCTAssertFalse(app.textFields["field-day"].exists, "The picker is the primary date control")
    tap(app.buttons["date-source-day"])
    XCTAssertEqual(app.textFields["field-day"].value as? String, "2024-02-29")
    tap(app.buttons["date-source-day"])
    XCTAssertTrue(day.exists, "Collapsing Date source must not clear the date")
    let image = app.scrollViews["image-previews-logo"]
    reveal(image, in: app)
    XCTAssertFalse(app.textFields["field-logo"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "native-svg-preview-and-compact-properties"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    tap(app.buttons["image-source-logo"])
    XCTAssertTrue(
      (app.descendants(matching: .any)["field-logo"].value as? String)?.hasPrefix(
        "data:image/svg+xml") == true)
  }

  func testInlineDoesNotOfferAnEditorForImmutableProperties() throws {
    let app = try openFixture("dates")
    defer { app.terminate() }
    app.navigationBars["Record"].buttons["done-record"].tap()
    let locked = app.buttons["inline-property-locked"].firstMatch
    for _ in 0..<10 where !locked.isHittable { app.swipeUp() }
    locked.tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["field-locked"].exists)
    XCTAssertFalse(app.buttons["inline-done"].exists)
  }

  func testLinkInputsRemainVisibleWithinCompactRows() throws {
    let app = try openFixture("dates")
    defer { app.terminate() }
    let field = app.textFields["field-website"]
    reveal(app.buttons["open-link-website"], in: app)
    XCTAssertGreaterThan(
      field.frame.height, 15, "The editable URL must not collapse to zero height")
    XCTAssertTrue(field.isHittable)
    let row = app.collectionViews["record-form"].cells.containing(
      .textField, identifier: "field-website"
    ).firstMatch
    XCTAssertGreaterThanOrEqual(
      row.frame.maxY - app.buttons["open-link-website"].frame.maxY, 4,
      "The link action must fit above its row separator")
  }

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
    tap(app.navigationBars["Record"].buttons["done-record"])
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not options for tags"))
        .firstMatch.waitForExistence(timeout: 5))
    reveal(removeUnknown, in: app, down: true)
    tap(removeUnknown)
    tap(app.navigationBars["Record"].buttons["done-record"])
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
    let daySource = app.buttons["date-source-day"]
    reveal(daySource, in: app)
    tap(daySource)
    XCTAssertEqual(app.textFields["field-day"].value as? String, "2024-02-29")
    reveal(app.buttons["clear-date-day"], in: app)
    tap(app.buttons["clear-date-day"])
    XCTAssertTrue(app.buttons["choose-date-day"].waitForExistence(timeout: 5))
    tap(app.navigationBars["Record"].buttons["done-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: "dates")
    let empty = app.collectionViews["record-form"].staticTexts["Empty properties"]
    reveal(empty, in: app)
    tap(empty)
    let choose = app.buttons["choose-date-day"]
    reveal(choose, in: app)
    tap(choose)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    tap(app.navigationBars["Record"].buttons["done-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    findRecord(app, record: "dates")
    reveal(daySource, in: app)
    tap(daySource)
    XCTAssertEqual(app.textFields["field-day"].value as? String, today)
    let momentSource = app.buttons["date-source-moment"]
    reveal(momentSource, in: app)
    tap(momentSource)
    XCTAssertEqual(app.textFields["field-moment"].value as? String, "2024-02-29T23:04:05.123Z")
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
      environment["IRIS_TEST_FIELDS_SIMULATOR"] == nil,
      "Requires the typed-fields fixture on an explicitly selected private simulator")
    guard let expected = environment["IRIS_TEST_FIELDS_SIMULATOR"], !expected.isEmpty,
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
