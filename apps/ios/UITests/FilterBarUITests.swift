import XCTest

/// The Notion-style filter bar on a private simulator's local sample workspace:
/// a select chip narrows the grid at once, sorting reorders it, closing a popover
/// saves the table's default view, Undo reverts the latest save and a relaunch
/// reopens the saved filter. Synthetic records only.
@MainActor
final class FilterBarUITests: XCTestCase {
  func testChipsApplyAtOnceSaveOnDismissUndoAndSurviveRelaunch() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["LIFE_UI_TEST_FILTER_BAR_SIMULATOR"] == nil,
      "Writes the local workspace; run on an explicitly selected private simulator")
    XCTAssertEqual(environment["LIFE_UI_TEST_FILTER_BAR_SIMULATOR"], environment["SIMULATOR_UDID"])
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    tap(app.buttons["open-local"])
    let start = record(app, "A place to start")
    XCTAssertTrue(start.waitForExistence(timeout: 15))

    tap(app.navigationBars["notes"].buttons["new-record"])
    let title = app.descendants(matching: .any)["field-title"]
    tap(title)
    title.typeText("Filterbar Ready")
    tap(app.buttons["field-status"])
    tap(app.buttons["Ready"])
    tap(app.navigationBars["New record"].buttons["save-record"])
    let ready = record(app, "Filterbar Ready")
    XCTAssertTrue(ready.waitForExistence(timeout: 10))

    tap(app.buttons["filter-bar-filter"])
    XCTAssertTrue(app.textFields["filter-property-search"].waitForExistence(timeout: 5))
    capture(app, "ios-1-filter-popover")
    tap(app.buttons["filter-property-status"])
    tap(app.buttons["filter-option-Ready"])
    XCTAssertTrue(app.buttons["filter-option-Ready"].isSelected)
    capture(app, "ios-2-chip-editing-select")
    tap(app.otherElements["PopoverDismissRegion"])
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
    gone(start)
    XCTAssertTrue(ready.exists)
    capture(app, "ios-3-narrowed-grid")

    tap(app.buttons["filter-bar-sort"])
    tap(app.buttons["add-sort"])
    tap(app.buttons["Title"])
    tap(app.buttons["sort-direction-0"])
    XCTAssertEqual(app.buttons["sort-direction-0"].label, "Title, descending")
    capture(app, "ios-4-sort-popover")
    tap(app.otherElements["PopoverDismissRegion"])
    XCTAssertTrue(app.buttons["sort-chip"].waitForExistence(timeout: 5))

    // The sort's save is the latest change; Undo reverts only it.
    tap(app.buttons["undo-saved-change"])
    gone(app.buttons["sort-chip"])
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
    capture(app, "ios-5-undo-reverted-sort")

    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
    XCTAssertTrue(app.buttons["filter-chip-0"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["filter-chip-0"].label, "Status: Ready")
    XCTAssertFalse(app.buttons["sort-chip"].exists)
    XCTAssertTrue(ready.waitForExistence(timeout: 10))
    XCTAssertFalse(start.exists)
    capture(app, "ios-6-relaunch-saved-filter")

    // Leave the private workspace unfiltered for the next run.
    tap(app.buttons["remove-filter-chip-0"])
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    Thread.sleep(forTimeInterval: 2)  // let the debounced save land before terminating
  }

  private func record(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  private func gone(_ element: XCUIElement) {
    let absent = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed)
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
