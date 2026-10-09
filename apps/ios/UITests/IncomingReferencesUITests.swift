import UIKit
import XCTest

@MainActor
final class IncomingReferencesUITests: XCTestCase {
  func testReadOnlyIncomingLinksShowPersistedIncompleteCoverageAfterReopen() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["IRIS_TEST_INCOMING_READ_ONLY"] == "1",
      "Requires the read-only partial-coverage fixture")
    let app = try openTarget()
    defer { app.terminate() }
    for pass in 0..<2 {
      XCTAssertFalse(app.buttons["save-record"].exists)
      let group = app.buttons["notes · Related topics"]
      reveal(group, in: app)
      tap(group)
      let warning = app.staticTexts["Some records may be missing on this device."]
      XCTAssertTrue(warning.waitForExistence(timeout: 5))
      reveal(warning, in: app)
      XCTAssertTrue(warning.exists)
      if pass == 0 {
        app.terminate()
        _ = try openTarget()
      }
    }
    capture(app, "native-incoming-read-only-partial-reopened")
    let source = app.buttons["Open Incoming 00"]
    reveal(source, in: app)
    tap(source)
    let fullBody = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Full incoming body 00")
    ).firstMatch
    reveal(fullBody, in: app)
    XCTAssertFalse(app.buttons["save-record"].exists)
    let emptyGroup = app.buttons["notes · Related topics"]
    reveal(emptyGroup, in: app, down: true)
    tap(emptyGroup)
    XCTAssertTrue(app.staticTexts["No stored records link here."].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Some records may be missing on this device."].exists)
  }

  func testIncomingPagesKeepDistinctIDsAndOpenTheFullSource() throws {
    let app = try openTarget()
    defer { app.terminate() }
    let group = app.buttons["notes · Topic"]
    reveal(group, in: app)
    XCTAssertFalse(app.buttons["Open Incoming 00"].exists, "Groups must start collapsed")
    tap(group)
    let more = app.buttons["incoming-more-notes-topic"]
    reveal(more, in: app)
    tap(more)
    let composed = app.buttons["Open Incoming composed"]
    reveal(composed, in: app)
    XCTAssertTrue(app.buttons["Open Incoming decomposed"].exists)
    XCTAssertFalse(app.buttons["Open Incoming deleted"].exists)
    XCTAssertFalse(more.exists)
    capture(app, "native-incoming-byte-distinct-pages")
    tap(composed)
    let title = app.textFields["field-title"]
    expectValue(title, "Incoming composed")
    let options = app.webViews.descendants(matching: .any)["Body options"]
    reveal(options, in: app)
    tap(options)
    tap(app.webViews.descendants(matching: .any)["Body source"])
    expectValue(app.webViews.textViews["Body"], "Composed full body")
    tap(app.navigationBars["Record"].buttons["Cancel"])
    openTargetRecord(app)
    reveal(group, in: app)
    tap(group)
    reveal(more, in: app)
    tap(more)
    let decomposed = app.buttons["Open Incoming decomposed"]
    reveal(decomposed, in: app)
    tap(decomposed)
    expectValue(title, "Incoming decomposed")
  }

  func testIncomingNavigationCancelAndEmbeddedMarkdownKeepTheDraftAndPanelUsable() throws {
    let app = try openTarget()
    defer { app.terminate() }
    let title = app.textFields["field-title"]
    tap(title)
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    title.typeText(" kept draft")
    let draft = try XCTUnwrap(title.value as? String)
    XCTAssertTrue(draft.contains("kept draft"))
    let group = app.buttons["notes · Related topics"]
    reveal(group, in: app)
    tap(group)
    let source = app.buttons["Open Incoming 00"]
    reveal(source, in: app)
    tap(source)
    tap(app.alerts.buttons["Keep editing"])
    reveal(title, in: app, down: true)
    expectValue(title, draft)
    let options = app.webViews.descendants(matching: .any)["Body options"]
    reveal(options, in: app)
    tap(options)
    tap(app.webViews.descendants(matching: .any)["Body source"])
    let sourceText = app.webViews.textViews["Body"]
    tap(sourceText)
    sourceText.typeText(" final keystroke")
    let bodyDraft = try XCTUnwrap(sourceText.value as? String)
    XCTAssertTrue(bodyDraft.contains("final keystroke"))
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          app.staticTexts["markdown-save-status"].label == "Saved on this device"
        }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    reveal(title, in: app, down: true)
    expectValue(title, draft)
    // Reappearing with a fresh panel model must reload an already expanded group.
    reveal(group, in: app)
    reveal(source, in: app)
    XCTAssertEqual(source.label, "Open Incoming 00")
    // Scroll from Content to a previously unopened group. Retained rows alone
    // would conceal a disposed model that can no longer make requests.
    let unvisited = app.buttons["notes · Topic"]
    reveal(unvisited, in: app)
    tap(unvisited)
    let anotherSource = app.buttons["Open Incoming 01"]
    reveal(anotherSource, in: app)
    capture(app, "native-incoming-draft-after-embedded-markdown")
    tap(anotherSource)
    tap(app.alerts.buttons["Discard changes and open"])
    expectValue(title, "Incoming 01")
    XCTAssertEqual(app.navigationBars.matching(identifier: "Record").count, 1)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    openTargetRecord(app)
    expectValue(title, "Target notebook")
    reveal(options, in: app)
    tap(options)
    tap(app.webViews.descendants(matching: .any)["Body source"])
    expectValue(sourceText, bodyDraft)
  }

  private func openTarget() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      environment["IRIS_TEST_INCOMING_SIMULATOR"] == nil,
      "Requires the incoming fixture on an explicitly selected private simulator")
    XCTAssertEqual(environment["IRIS_TEST_INCOMING_SIMULATOR"], environment["SIMULATOR_UDID"])
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    tap(app.buttons["open-local"])
    openTargetRecord(app)
    return app
  }

  private func openTargetRecord(_ app: XCUIApplication) {
    let title = "Target notebook"
    let record = app.buttons["open-record-incoming-target"]
    if record.exists && record.isHittable {
      XCTAssertEqual(record.label, title + ", Open record")
      tap(record)
    } else {
      tap(app.buttons["quick-find"])
      let query = app.textFields["quick-find-query"]
      tap(query)
      query.typeText(title)
      tap(app.buttons["quick-find-result-notes-incoming-target"])
    }
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["record-heading"].label, title)
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
      var bottom = area.maxY - 34
      if keyboard.exists {
        bottom = min(bottom, keyboard.frame.minY - 52)
        let accessory = app.toolbars.containing(.button, identifier: "Done").firstMatch
        if accessory.exists { bottom = min(bottom, accessory.frame.minY - 10) }
      }
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

  private func expectValue(
    _ element: XCUIElement, _ value: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let expected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.value as? String == value }
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
