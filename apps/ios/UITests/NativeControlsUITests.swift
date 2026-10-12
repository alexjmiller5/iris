import XCTest

@MainActor
final class NativeControlsUITests: XCTestCase {
  func testWorkspaceStatusShowsInstalledAppVersion() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["workspace-status"].tap()
    XCTAssertTrue(app.navigationBars["Workspace status"].waitForExistence(timeout: 5))
    let version = app.descendants(matching: .any)["app-version"].firstMatch
    XCTAssertTrue(version.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(version.isHittable, "Installed version must be visible in workspace status")
    XCTAssertEqual(version.label, "App version, 1.0 (1)")
    capture(app, "native-installed-app-version")
    app.buttons["status-done"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 5))
  }

  func testSelectPickerOffersNoneAndNoTypedValueRow() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    let status = app.buttons["field-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Enter a value"].exists, "Loaded choices need no typed value")
    XCTAssertFalse(app.textFields["field-status-source"].exists)
    capture(app, "native-choice-picker")
    status.tap()
    XCTAssertTrue(app.buttons["None"].waitForExistence(timeout: 5), "The clear choice is visible")
    app.buttons["Ready"].tap()
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(
          format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "field-status",
          "Ready", "Ready")
      )
      .firstMatch.waitForExistence(timeout: 5))
    capture(app, "native-choice-chosen")
  }

  func testEmptyValuesReadEmptyAndWrapAllColumnsShowsWholeValues() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    let long =
      "A synthetic note whose title keeps going well past the width of one list row and then some more words after that"
    app.navigationBars["notes"].buttons["new-record"].tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    title.tap()
    title.typeText(long)
    app.buttons["done-record"].firstMatch.tap()
    let row = app.buttons.matching(NSPredicate(format: "label == %@", "Edit Title")).matching(
      NSPredicate(format: "value == %@", long)
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
    let clipped = row.frame.height
    app.buttons["Empty properties"].firstMatch.tap()
    let related = app.buttons["inline-property-related"].firstMatch
    XCTAssertTrue(related.waitForExistence(timeout: 5))
    // Blank on screen; VoiceOver hears the label and "Empty".
    let spoken = related.label + " " + ((related.value as? String) ?? "")
    XCTAssertTrue(spoken.contains("Empty"), spoken)
    XCTAssertFalse(spoken.contains("Not set"), spoken)
    capture(app, "native-empty-property")
    app.buttons["saved-views"].tap()
    let wrapAll = app.switches["wrap-all-columns"]
    XCTAssertTrue(wrapAll.waitForExistence(timeout: 5))
    XCTAssertEqual(wrapAll.value as? String, "0")
    wrapAll.switches.firstMatch.tap()
    XCTAssertEqual(wrapAll.value as? String, "1")
    capture(app, "native-wrap-all-toggle")
    app.navigationBars.buttons["Done"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 5))
    let wrapped = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { row.exists && row.frame.height > clipped }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [wrapped], timeout: 10), .completed)
    capture(app, "native-wrapped-row")
    app.buttons["saved-views"].tap()
    XCTAssertEqual(app.switches["wrap-all-columns"].value as? String, "1", "The view saved it")
  }

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
    // Graph nodes are named by their visible text: "<table> <n> columns".
    let node = { (name: String) in
      app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + " "))
        .firstMatch
    }
    let table = node("topics")
    XCTAssertTrue(table.waitForExistence(timeout: 10), app.debugDescription)
    for name in ["notes", "topics", "history", "views"] {
      let target = node(name)
      XCTAssertTrue(target.exists)
      XCTAssertGreaterThanOrEqual(target.frame.minX, app.webViews.firstMatch.frame.minX)
      XCTAssertLessThanOrEqual(target.frame.maxX, app.webViews.firstMatch.frame.maxX)
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
      "saved-views", "filter-bar-filter", "filter-bar-sort", "quick-find", "schema-graph",
      "workspace-menu", "new-record",
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
