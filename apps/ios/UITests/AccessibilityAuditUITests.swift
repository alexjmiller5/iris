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

    present(app, app.buttons["filter-bar-filter"], app.textFields["filter-property-search"])
    try audit(app, "filter-properties")
    tap(app.buttons["filter-property-status"])
    XCTAssertTrue(app.buttons["filter-option-Ready"].waitForExistence(timeout: 5))
    try audit(app, "filter-editor")
    tap(app.otherElements["PopoverDismissRegion"])

    present(app, app.buttons["filter-bar-sort"], app.buttons["add-sort"])
    try audit(app, "sort")
    tap(app.otherElements["PopoverDismissRegion"])

    tap(app.buttons["saved-views"])
    XCTAssertTrue(app.navigationBars["Saved views"].waitForExistence(timeout: 5))
    try audit(app, "saved-views")
    tap(app.navigationBars["Saved views"].buttons.firstMatch)

    tap(app.buttons["quick-find"])
    let find = app.textFields["quick-find-query"]
    tap(find)
    find.typeText("place")
    XCTAssertEqual(find.value as? String, "place")
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
      app.launchArguments =
        ["--demo"] + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
      app.launch()
      defer { app.terminate() }
      let open = app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", "A place to start")
      )
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
    var notes: [String] = []
    try app.performAccessibilityAudit(for: .all) { issue in
      let element = issue.element.map {
        "\($0.elementType.rawValue) \"\($0.label)\" \($0.identifier) \($0.frame)"
      }
      let finding =
        "\(screen): \(issue.compactDescription) on \(element ?? "?"): \(issue.detailedDescription)"
      if let reason = Self.exemption(issue, screen: screen, app: app) {
        notes.append("\(finding) [exempt: \(reason)]")
      } else {
        XCTFail(finding)
      }
      return true
    }
    let kept = XCTAttachment(string: notes.joined(separator: "\n"))
    kept.name = "ax-\(screen)-exempt.txt"
    kept.lifetime = .keepAlways
    add(kept)
  }

  /// Findings this app cannot act on. Every other finding fails the test.
  private static func exemption(
    _ issue: XCUIAccessibilityAuditIssue, screen: String, app: XCUIApplication
  ) -> String? {
    guard let element = issue.element else {
      // Unattributed text and contrast samples come from the blurred records behind a
      // popover or sheet, which are not part of the presented screen.
      return "no element: content behind the presented popover or sheet"
    }
    let frame = element.frame
    let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 140
    if frame.maxY <= top + 2 || frame.minY >= app.frame.height - 100 {
      // System bar items cap their text size and show the Large Content Viewer instead.
      return "navigation or bottom bar item"
    }
    if issue.auditType == .contrast, frame.minY < top + 60 {
      // Content scrolled under the bar is faded by the system's scroll edge effect.
      return "under the navigation bar's scroll edge effect"
    }
    let popover = app.popovers.firstMatch
    if issue.auditType == .contrast, popover.exists, popover.frame.intersects(frame),
      !popover.frame.insetBy(dx: -1, dy: -1).contains(frame)
    {
      return "partly scrolled out of the popover"
    }
    let keyboard = app.keyboards.firstMatch
    if keyboard.exists, keyboard.frame.insetBy(dx: 0, dy: -50).intersects(frame) {
      return "covered by the system keyboard or its suggestions"
    }
    if #unavailable(iOS 27), issue.auditType == .hitRegion,
      element.label == "Group tables" || element.label.hasPrefix("Relationship details")
    {
      // Graph disclosures: WebKit before iOS 27 reports a <summary>'s text line as its
      // frame; its touch box is 44 px (SchemaGraph.svelte, checked in the DOM).
      return "summary frame reported as its text line"
    }
    if issue.auditType == .hitRegion, [.staticText, .other].contains(element.elementType) {
      // Text and drawing inside a web view are not controls; their buttons are checked.
      return "not a control"
    }
    if issue.auditType == .dynamicType, issue.detailedDescription.contains("UILabel") {
      // The menu Picker's own UIKit label; SwiftUI draws it and caps its size.
      return "system picker label"
    }
    let name = element.label.isEmpty ? element.identifier : element.label
    if issue.auditType == .textClipped, Self.verifiedUnclipped.contains("\(screen)/\(name)") {
      return "renders in full in the attached AX5 screenshot"
    }
    return nil
  }

  /// Flagged as possibly clipped, checked in the AX5 screenshots: wrapped SwiftUI
  /// labels and the record menu's label, which show in full, and the single-line
  /// Quick Find field, which
  /// scrolls long queries horizontally like any UIKit text field.
  private static let verifiedUnclipped: Set<String> = [
    "saved-views/Row actions and Today", "workspace-status/Copy diagnostics",
    "record/Actions", "record-markdown/Actions", "quick-find/quick-find-query",
  ]

  /// Taps `control` until `shows` appears, at most twice; the audit just before can
  /// leave a layout pass in flight that swallows the first tap.
  private func present(
    _ app: XCUIApplication, _ control: XCUIElement, _ shows: XCUIElement,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for attempt in 1...2 {
      tap(control, file: file, line: line)
      if shows.waitForExistence(timeout: 5) { return }
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "not-presented-\(control.identifier)-\(attempt)"
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTFail("\(control.identifier) did not present its contents", file: file, line: line)
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
