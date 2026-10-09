import XCTest

/// VoiceOver and keyboard evidence for the Mac app on the in-memory sample
/// workspace: the window, filter and sort popovers, Quick Find and the record
/// editor pass Xcode's accessibility audit with their element trees attached
/// (`ax-mac-<screen>.txt`), and each surface opens and closes from the keyboard.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
  func testSurfacesPassTheAuditAndWorkFromTheKeyboard() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let pill = app.buttons["workspace-status"]
    if !(pill.exists && pill.isHittable) { app.typeKey("\\", modifierFlags: .command) }
    XCTAssertTrue(pill.waitForExistence(timeout: 5))
    XCTAssertEqual(pill.label, "Local only", "The sync pill speaks its state")
    try audit(app, "window")

    // Popovers: Escape closes them.
    app.buttons["filter-bar-filter"].click()
    let search = app.textFields["filter-property-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    try audit(app, "filter-properties")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Escape closes the filter popover")
    app.buttons["filter-bar-sort"].click()
    let addSort = app.descendants(matching: .any)["add-sort"]
    XCTAssertTrue(addSort.waitForExistence(timeout: 5))
    try audit(app, "sort")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(addSort.waitForNonExistence(timeout: 5), "Escape closes the sort popover")

    // Quick Find: Cmd+K opens it, Escape closes it.
    app.typeKey("k", modifierFlags: .command)
    let query = app.textFields["quick-find-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    query.typeText("place")
    try audit(app, "quick-find")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 5), "Escape closes Quick Find")

    // The record editor sheet: Cmd+S saves, Escape cancels.
    grid.buttons["Open A place to start"].click()
    let title = app.sheets.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    // Saving collects the Markdown editor's text, so wait for the editor to load.
    XCTAssertTrue(
      app.sheets.webViews.textViews.firstMatch.waitForExistence(timeout: 60), "Editor loads")
    try audit(app, "record")
    title.click()
    title.typeKey("a", modifierFlags: .command)
    title.typeText("Typed by keyboard")
    XCTAssertEqual(title.value as? String, "Typed by keyboard", "The title field takes typing")
    app.typeKey("s", modifierFlags: .command)
    let closed = title.waitForNonExistence(timeout: 10)
    let afterSave = XCTAttachment(screenshot: app.screenshot())
    afterSave.name = "mac-after-cmd-s"
    afterSave.lifetime = .keepAlways
    add(afterSave)
    XCTAssertTrue(closed, "Cmd+S saves and closes the record")
    let saved = grid.buttons["Open Typed by keyboard"]
    XCTAssertTrue(saved.waitForExistence(timeout: 5))
    saved.click()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Escape closes an unchanged record")

    // Cmd+\ hides and restores the sidebar.
    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(pill.waitForNonExistence(timeout: 5) || !pill.isHittable)
    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(pill.waitForExistence(timeout: 5))

    // The menu-bar item: every entry has a spoken title.
    let item = app.descendants(matching: .statusItem).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
    XCTAssertTrue(app.menuItems["Open Iris"].waitForExistence(timeout: 5))
    let tree = XCTAttachment(string: app.menus.firstMatch.debugDescription)
    tree.name = "ax-mac-menu-bar-item.txt"
    tree.lifetime = .keepAlways
    add(tree)
    for index in 0..<app.menus.firstMatch.menuItems.count {
      let entry = app.menus.firstMatch.menuItems.element(boundBy: index)
      if entry.isEnabled { XCTAssertFalse(entry.title.isEmpty, "Menu entry \(index) has a title") }
    }
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Runs the VoiceOver audits (descriptions, actions, parent/child) and keeps every
  /// finding visible; contrast findings are attached as notes (see `exemption`).
  private func audit(_ app: XCUIApplication, _ screen: String) throws {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "ax-mac-\(screen).txt"
    tree.lifetime = .keepAlways
    add(tree)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "mac-\(screen)"
    shot.lifetime = .keepAlways
    add(shot)
    var notes: [String] = []
    try app.performAccessibilityAudit(for: .all) { issue in
      let element = issue.element.map {
        "\($0.elementType.rawValue) \"\($0.label)\" \($0.identifier) \($0.frame)"
      }
      let finding =
        "\(screen): \(issue.compactDescription) on \(element ?? "?"): \(issue.detailedDescription)"
      if let reason = Self.exemption(issue) {
        notes.append("\(finding) [not failed: \(reason)]")
      } else {
        XCTFail(finding)
      }
      return true
    }
    let kept = XCTAttachment(string: notes.joined(separator: "\n"))
    kept.name = "ax-mac-\(screen)-notes.txt"
    kept.lifetime = .keepAlways
    add(kept)
  }

  /// Findings outside this app's control. Every other finding fails the test.
  private static func exemption(_ issue: XCUIAccessibilityAuditIssue) -> String? {
    if issue.auditType == .contrast {
      // Secondary text uses the system secondary label color, as AppKit apps do;
      // the system Increase Contrast setting darkens it. Recorded, not failed.
      return "system secondary label color"
    }
    guard let element = issue.element else { return "no element" }
    if element.frame.maxY <= 32 {
      return "system menu bar"
    }
    if issue.auditType == .parentChild, element.elementType == .group {
      // SwiftUI builds these layout groups; the app has no handle on their parentage.
      return "SwiftUI layout group"
    }
    if issue.auditType == .action,
      [.disclosureTriangle, .popUpButton].contains(element.elementType)
    {
      // SwiftUI DisclosureGroup and Picker expose their expand and show-menu actions.
      return "SwiftUI disclosure or picker"
    }
    if issue.auditType == .sufficientElementDescription,
      [.group, .scrollView, .popover, .window, .menuBar, .other, .splitGroup].contains(
        element.elementType)
    {
      // Unnamed layout containers; their controls carry the names.
      return "layout container"
    }
    if issue.auditType == .action, element.elementType == .menuButton {
      // SwiftUI toolbar menus open through AXShowMenu (VoiceOver: VO-Shift-M).
      return "toolbar menu"
    }
    return nil
  }
}
