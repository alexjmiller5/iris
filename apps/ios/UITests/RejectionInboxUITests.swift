import UIKit
import XCTest

/// Seed RejectionInboxUIFixtureTests on the same explicitly selected simulator first.
/// These flows are offline and use separate rows; their execution order is irrelevant.
@MainActor
final class RejectionInboxUITests: XCTestCase {
  func testOfflineInboxReviewKeepsDraftAcrossRelaunchAndSavesCurrentRevision() throws {
    let app = try openFixture()
    defer { app.terminate() }
    openIssues(app)
    XCTAssertTrue(reviewButton(app, id: "issues-save").exists)
    tap(app.navigationBars["Issues"].buttons["Done"])
    XCTAssertTrue(app.navigationBars["Issues"].waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Record"].exists, "Cancelling Issues must not open an editor")

    relaunchLocal(app)
    openIssues(app)
    tap(reviewButton(app, id: "issues-save"))
    XCTAssertTrue(app.navigationBars["Issues"].waitForNonExistence(timeout: 5))
    let title = app.textFields["field-title"]
    expectValue(title, "Issues save submitted")
    XCTAssertTrue(
      app.staticTexts["Autosave paused. Review your draft, then save the record."].exists)
    XCTAssertFalse(app.textFields["field-locked"].exists)
    XCTAssertFalse(app.textFields["field-retired"].exists)
    XCTAssertFalse(app.textFields["field-removed"].exists)
    XCTAssertFalse(app.textFields["field-updated_at"].exists)
    expectBody(app, "Rejected save body")
    // Read-only rows expose one combined "column, value" label.
    reveal(showing("Locked current", in: app), in: app)
    XCTAssertFalse(showing("Locked rejected", in: app).exists)
    XCTAssertFalse(showing("Removed submitted value", in: app).exists)
    capture(app, "issues-current-baseline-editable-only")
    keepAndClose(app)

    relaunchLocal(app)
    findRecord(app, id: "issues-save", title: "Issues save current")
    tap(app.buttons["Resume draft"])
    expectValue(title, "Issues save submitted")
    expectBody(app, "Rejected save body")
    // The submitted payload predates the current row. Success proves Review used
    // the current revision, and the relaunch proves the paused journal was durable.
    tap(app.navigationBars["Record"].buttons["save-record"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    findRecord(app, id: "issues-save", title: "Issues save submitted")
    expectValue(title, "Issues save submitted")
    XCTAssertFalse(app.buttons["Resume draft"].exists)
    expectBody(app, "Rejected save body")
    tap(app.navigationBars["Record"].buttons["Cancel"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 5))
    openIssues(app)
    XCTAssertTrue(
      reviewButton(app, id: "issues-save").exists,
      "A local correction must not remove a durable rejection before an accepted sync")
    capture(app, "issues-correction-retains-inbox")
    tap(app.navigationBars["Issues"].buttons["Done"])
    XCTAssertTrue(app.navigationBars["Issues"].waitForNonExistence(timeout: 5))
  }

  func testNewerSavedRevisionRejectsResumedReviewAndKeepsItsJournal() throws {
    let app = try openFixture()
    defer { app.terminate() }
    findRecord(app, id: "issues-stale", title: "Issues stale newer")
    let title = app.textFields["field-title"]
    expectValue(title, "Issues stale newer")
    tap(app.buttons["Resume draft"])
    expectValue(title, "Issues stale submitted")
    tap(app.navigationBars["Record"].buttons["save-record"])
    let conflict = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Row changed since it was selected")
    ).firstMatch
    reveal(conflict, in: app)
    XCTAssertTrue(app.navigationBars["Record"].exists)
    reveal(title, in: app, down: true)
    expectValue(title, "Issues stale submitted")
    expectBody(app, "Rejected stale body")
    capture(app, "issues-stale-save-keeps-review")
    keepAndClose(app)

    relaunchLocal(app)
    findRecord(app, id: "issues-stale", title: "Issues stale newer")
    tap(app.buttons["Resume draft"])
    expectValue(title, "Issues stale submitted")
    expectBody(app, "Rejected stale body")
    keepAndClose(app)
    // Opening the stored row instead of resuming must still show the newer
    // record. Merely inspecting it must not discard the failed review journal.
    findRecord(app, id: "issues-stale", title: "Issues stale newer")
    tap(app.buttons["Open saved record"])
    expectValue(title, "Issues stale newer")
    expectBody(app, "Newer saved body")
    tap(app.navigationBars["Record"].buttons["Cancel"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 5))
    findRecord(app, id: "issues-stale", title: "Issues stale newer")
    XCTAssertTrue(app.buttons["Resume draft"].waitForExistence(timeout: 5))
    capture(app, "issues-stale-journal-and-newer-row-preserved")
  }

  private func openFixture() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard let requested = environment["LIFE_UI_TEST_REJECTIONS_SIMULATOR"], !requested.isEmpty
    else { throw XCTSkip("Requires the explicitly opted-in private simulator Issues fixture") }
    continueAfterFailure = false
    XCTAssertEqual(requested, environment["SIMULATOR_UDID"])
    guard requested == environment["SIMULATOR_UDID"] else {
      throw NSError(domain: "RejectionInboxUITests", code: 1)
    }
    let app = XCUIApplication()
    app.launch()
    tap(app.buttons["open-local"])
    return app
  }

  private func relaunchLocal(_ app: XCUIApplication) {
    app.terminate()
    app.launch()
    tap(app.buttons["open-local"])
  }

  private func openIssues(_ app: XCUIApplication) {
    tap(app.buttons["workspace-menu"])
    tap(app.buttons["workspace-issues"])
    XCTAssertTrue(app.staticTexts["rejected-edit-count"].waitForExistence(timeout: 10))
  }

  private func reviewButton(_ app: XCUIApplication, id: String) -> XCUIElement {
    let button = app.buttons.matching(
      NSPredicate(format: "label == %@", "Review edit in ui_rejections, record \(id)")
    ).firstMatch
    let list = app.collectionViews.firstMatch
    for _ in 0..<8 {
      if button.exists && button.isHittable { return button }
      let more = app.buttons["load-more-rejected-edits"]
      if more.exists && more.isHittable { tap(more) } else { list.swipeUp() }
    }
    XCTAssertTrue(button.exists && button.isHittable, app.debugDescription)
    return button
  }

  private func findRecord(_ app: XCUIApplication, id: String, title: String) {
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.typeText(title)
    tap(app.buttons["quick-find-result-ui_rejections-\(id)"])
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
  }

  private func expectBody(_ app: XCUIApplication, _ expected: String) {
    let options = app.webViews.descendants(matching: .any)["Body options"]
    reveal(options, in: app)
    tap(options)
    tap(app.webViews.descendants(matching: .any)["Body source"])
    expectValue(app.webViews.textViews["Body"], expected)
    XCTAssertTrue(app.navigationBars["Record"].exists)
  }

  private func keepAndClose(_ app: XCUIApplication) {
    tap(app.navigationBars["Record"].buttons["keep-record-draft"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
  }

  private func showing(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
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
        element.exists && element.frame.height > 0 ? element.frame.midY < area.minY : down
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
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.exists && element.isHittable && element.isEnabled }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }

  private func expectValue(
    _ element: XCUIElement, _ value: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let expected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.exists && element.value as? String == value }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed, file: file, line: line)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
