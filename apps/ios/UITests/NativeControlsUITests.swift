import XCTest

@MainActor
final class NativeControlsUITests: XCTestCase {
  func testCompactControlsStatusAndGraphNavigation() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    let graph = app.buttons["schema-graph"]
    XCTAssertTrue(graph.waitForExistence(timeout: 3), "Graph must be discoverable on iPhone")
    XCTAssertTrue(graph.isHittable)
    let views = app.buttons["saved-views"]
    XCTAssertTrue(views.isHittable)
    XCTAssertGreaterThan(views.frame.minY, app.frame.height * 0.7)
    XCTAssertLessThan(app.navigationBars["notes"].frame.height, 65)
    capture(app, "native-compact-records")
    app.buttons["workspace-status"].tap()
    XCTAssertTrue(app.navigationBars["Workspace status"].waitForExistence(timeout: 3))
    capture(app, "native-status-details")
    app.buttons["status-done"].tap()
    graph.tap()
    XCTAssertTrue(app.navigationBars["Schema graph"].waitForExistence(timeout: 3))
    let table = app.webViews.buttons["Open table topics"]
    XCTAssertTrue(table.waitForExistence(timeout: 10), app.debugDescription)
    for name in ["notes", "topics", "history", "views"] {
      let node = app.webViews.buttons["Open table " + name]
      XCTAssertTrue(node.exists)
      XCTAssertGreaterThanOrEqual(node.frame.minX, app.webViews.firstMatch.frame.minX)
      XCTAssertLessThanOrEqual(node.frame.maxX, app.webViews.firstMatch.frame.maxX)
    }
    capture(app, "native-schema-graph")
    let fittedWidth = table.frame.width
    app.webViews.buttons["Zoom in"].tap()
    XCTAssertGreaterThan(table.frame.width, fittedWidth)
    capture(app, "native-schema-graph-readable-zoom")
    // aria-pressed exposes the native WebKit fit control as a toggle, not a plain button.
    app.webViews.descendants(matching: .any)["Fit graph"].firstMatch.tap()
    XCTAssertEqual(table.frame.width, fittedWidth, accuracy: 1)
    let relationships = app.webViews.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", "Relationship details (")
    ).firstMatch
    XCTAssertTrue(relationships.exists)
    relationships.tap()
    capture(app, "native-graph-relationships")
    app.buttons["graph-done"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 3))
    graph.tap()
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    let details = app.webViews.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", "Relationship details (")
    ).firstMatch
    details.tap()
    let related = app.webViews.buttons["topics"].firstMatch
    XCTAssertTrue(related.waitForExistence(timeout: 5))
    related.tap()
    XCTAssertTrue(app.navigationBars["topics"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.navigationBars["Schema graph"].exists)
    app.buttons["workspace-menu"].tap()
    XCTAssertTrue(app.buttons["Hub connection"].waitForExistence(timeout: 3))
    capture(app, "native-workspace-menu")
    app.buttons["Hub connection"].tap()
    XCTAssertTrue(app.navigationBars["Hub connection"].waitForExistence(timeout: 5))
    app.navigationBars["Hub connection"].buttons["Done"].tap()
    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    XCTAssertTrue(app.buttons["schema-graph-sidebar"].waitForExistence(timeout: 5))
    capture(app, "native-compact-sidebar")
    app.buttons["schema-graph-sidebar"].tap()
    XCTAssertTrue(app.buttons["graph-done"].waitForExistence(timeout: 5))
    app.buttons["graph-done"].tap()
    app.buttons["workspace-menu"].tap()
    app.buttons["Close workspace"].tap()
    XCTAssertTrue(app.buttons["open-local"].waitForExistence(timeout: 5))
  }

  func testControlsAtAccessibilityTextSize() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    for identifier in [
      "saved-views", "view-options", "quick-find", "schema-graph", "workspace-menu", "new-record",
    ] {
      let button = app.buttons[identifier]
      XCTAssertTrue(button.isHittable, identifier)
      XCTAssertFalse(button.label.isEmpty)
    }
    // Native toolbar accessibility frames describe the visual item, not its expanded hit region.
    try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
    capture(app, "native-accessibility-controls")
    let views = app.buttons["saved-views"]
    views.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 0, dy: 21)).tap()
    XCTAssertTrue(app.navigationBars["Saved views"].waitForExistence(timeout: 5))
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
