import XCTest

/// VoiceOver and Dynamic Type evidence for every iPhone screen of the in-memory
/// sample workspace at the largest accessibility text size: each screen passes
/// Xcode's accessibility audit, and its element tree and a screenshot are kept
/// as attachments (`ax-<screen>.txt`, `ax5-<screen>`). Synthetic data only.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
  func testEveryScreenPassesTheAuditAtAccessibilityTextSize() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 20))
    try audit(app, "records")

    tap(app.buttons["filter-bar-filter"])
    XCTAssertTrue(app.textFields["filter-property-search"].waitForExistence(timeout: 5))
    try audit(app, "filter-properties")
    tap(app.buttons["filter-property-status"])
    XCTAssertTrue(app.buttons["filter-option-Ready"].waitForExistence(timeout: 5))
    try audit(app, "filter-editor")
    tap(app.otherElements["PopoverDismissRegion"])

    tap(app.buttons["filter-bar-sort"])
    XCTAssertTrue(app.buttons["add-sort"].waitForExistence(timeout: 5))
    try audit(app, "sort")
    tap(app.otherElements["PopoverDismissRegion"])

    tap(app.buttons["saved-views"])
    XCTAssertTrue(app.navigationBars["Saved views"].waitForExistence(timeout: 5))
    try audit(app, "saved-views")
    tap(app.navigationBars["Saved views"].buttons.firstMatch)

    tap(app.buttons["quick-find"])
    let find = app.searchFields.firstMatch
    XCTAssertTrue(find.waitForExistence(timeout: 5))
    find.typeText("place")
    try audit(app, "quick-find")
    tap(app.buttons["Cancel"].firstMatch)

    tap(app.buttons["workspace-status"])
    XCTAssertTrue(app.navigationBars["Workspace status"].waitForExistence(timeout: 5))
    try audit(app, "workspace-status")
    tap(app.buttons["status-done"])

    tap(app.buttons["schema-graph"])
    XCTAssertTrue(app.navigationBars["Schema graph"].waitForExistence(timeout: 5))
    try audit(app, "schema-graph")
    tap(app.buttons["graph-done"])

    let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch
    tap(open)
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 10))
    try audit(app, "record")
    reveal(app, app.webViews.textViews["Body"])
    try audit(app, "record-markdown")
  }

  /// The rich Markdown editor is a WebKit island; it must follow the reader's
  /// Dynamic Type size like the native fields around it. WebKit exposes the
  /// document as one text view, so the paired screenshots show the text itself
  /// and the frame shows the editor growing with it.
  func testRichEditorFollowsDynamicType() throws {
    func editorHeight(_ size: String?) -> CGFloat {
      let app = XCUIApplication()
      app.launchArguments = ["--demo"] + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
      app.launch()
      defer { app.terminate() }
      let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
        .firstMatch
      tap(open)
      let rich = app.webViews.textViews["Body"]
      reveal(app, rich)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "rich-editor-\(size ?? "default")"
      shot.lifetime = .keepAlways
      add(shot)
      return rich.frame.height
    }
    let regular = editorHeight(nil)
    let large = editorHeight("UICTContentSizeCategoryAccessibilityXXXL")
    XCTAssertGreaterThan(large, regular * 1.5, "The editor must grow with AX5 text")
  }

  /// Runs the audit, keeping every finding visible in the failure message.
  private func audit(_ app: XCUIApplication, _ screen: String) throws {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "ax-\(screen).txt"
    tree.lifetime = .keepAlways
    add(tree)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "ax5-\(screen)"
    shot.lifetime = .keepAlways
    add(shot)
    try app.performAccessibilityAudit(for: .all) { issue in
      let element = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.identifier)" }
      XCTFail("\(screen): \(issue.auditType) \(issue.compactDescription) on \(element ?? "?")")
      return true
    }
  }

  /// Lazy record forms create rows below the fold only when scrolled to.
  private func reveal(
    _ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for _ in 0..<12 where !(element.waitForExistence(timeout: 1) && element.isHittable) {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable, app.debugDescription, file: file, line: line)
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { element.isHittable } },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }
}
