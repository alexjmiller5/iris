import XCTest

@MainActor
final class NotesViewsUITests: XCTestCase {
  /// The preferred default view, a Someday view, a related-record view that keeps
  /// History and hides Retired, a flag quick filter with its inline reason and a
  /// status-labeled search result, all from catalog and saved-view data.
  func testLifecycleViewsFlagReasonAndStatusLabeledSearch() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["IRIS_TEST_NOTES_VIEWS_SIMULATOR"] == nil,
      "Requires the notes-views fixture on an explicitly selected private simulator")
    XCTAssertEqual(environment["IRIS_TEST_NOTES_VIEWS_SIMULATOR"], environment["SIMULATOR_UDID"])
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    tap(app.buttons["open-local"])

    open(app, query: "notes", result: "quick-find-table-notes")
    let working = app.buttons["open-record-nv-working"]
    XCTAssertTrue(working.waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["open-record-nv-reference"].exists)
    XCTAssertFalse(app.buttons["open-record-nv-someday"].exists)
    capture(app, "ios-1-default-everyday")

    tap(app.buttons["saved-views"])
    tap(app.buttons["Someday"])
    XCTAssertTrue(app.buttons["open-record-nv-someday"].waitForExistence(timeout: 10))
    gone(working)
    capture(app, "ios-2-someday")

    open(app, query: "notes", result: "quick-find-table-notes")
    XCTAssertTrue(working.waitForExistence(timeout: 10))
    tap(app.buttons["flag-chip-needs_review"])
    gone(working)
    XCTAssertTrue(app.buttons["open-record-nv-reference"].exists)
    let reason = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Duplicates the packing list")
    ).firstMatch
    XCTAssertTrue(reason.waitForExistence(timeout: 10))
    capture(app, "ios-4-needs-review-reason")

    open(app, query: "Synthetic trip", result: "quick-find-result-topics-nv-trip")
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))
    let group = app.buttons["notes · Topic"]
    reveal(group, in: app)
    tap(group)
    let history = app.buttons["Open History log"]
    reveal(history, in: app)
    XCTAssertTrue(app.buttons["Open Working draft"].exists)
    XCTAssertFalse(app.buttons["Open Retired lantern plan"].exists)
    capture(app, "ios-3-related-history-not-retired")
    tap(app.navigationBars["Record"].buttons["done-record"])

    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeText("lantern")
    XCTAssertTrue(app.buttons["quick-find-result-notes-nv-retired"].waitForExistence(timeout: 10))
    let status = app.staticTexts["quick-find-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertEqual(status.label, "Status Retired")
    capture(app, "ios-5-search-retired-label")
  }

  private func open(_ app: XCUIApplication, query text: String, result: String) {
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeText(text)
    tap(app.buttons[result])
  }

  private func gone(_ element: XCUIElement) {
    let absent = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    let form = app.collectionViews["record-form"]
    for _ in 0..<8 where !(element.exists && element.isHittable) {
      form.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(element.waitForExistence(timeout: 5))
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
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
