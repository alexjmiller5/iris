import XCTest

@MainActor
final class TableNavigationUITests: XCTestCase {
  func testCachedNavigationAndSaveCompleteWhileSyncHTTPIsHeld() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] == env["SIMULATOR_UDID"]
        && env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] != nil,
      "Use only the explicitly selected disposable simulator.")
    let endpoint = try XCTUnwrap(env["LIFE_UI_TEST_TABLE_NAV_HUB"])
    @Sendable func gate(_ action: String) async throws -> Bool {
      let (data, _) = try await URLSession.shared.data(
        from: XCTUnwrap(URL(string: endpoint + "/fixture/" + action)))
      return (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["waiting"] ?? false
    }
    addTeardownBlock { _ = try await gate("release") }
    _ = try await gate("hold")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15), app.debugDescription)
    var waiting = false
    for _ in 0..<100 {
      waiting = try await gate("status")
      if waiting { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(waiting, "The real sync transport must remain held during local operations")
    tap(app.navigationBars.buttons["BackButton"].firstMatch, app)
    revealSidebar(app.buttons["System tables"], app)
    tap(app.buttons["System tables"], app)
    let provenance = app.buttons["sidebar-table-provenance"]
    revealSidebar(provenance, app)
    tap(provenance, app)
    XCTAssertTrue(
      app.navigationBars["provenance"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.buttons["cancel-destination"].exists)
    tap(app.navigationBars.buttons["BackButton"].firstMatch, app)
    let notes = app.buttons["sidebar-table-notes"]
    revealSidebar(notes, app)
    tap(notes, app)
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 5), app.debugDescription)
    tap(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
        .firstMatch, app)
    let title = app.textFields["field-title"]
    tap(title, app)
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    title.typeText(" saved during sync")
    let savedTitle = try XCTUnwrap(title.value as? String)
    tap(app.buttons["save-record"], app)
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 5), app.debugDescription)
    let menu = app.buttons["workspace-menu"]
    if menu.exists { tap(menu, app) }
    XCTAssertTrue(app.buttons["sync-now"].exists)
    XCTAssertFalse(
      app.buttons["sync-now"].isEnabled, "The sync must still be active after the save")
    if menu.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap() }
    tap(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", savedTitle)).firstMatch, app)
    XCTAssertEqual(
      title.value as? String, savedTitle, "Reopening must read the locally committed edit")
    let stillHeld = try await gate("status")
    XCTAssertTrue(stillHeld, "Local navigation and save must not wait for sync")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "local-save-while-sync-held"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testLargeSystemTableDoesNotLockTheSidebar() throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] == env["SIMULATOR_UDID"]
        && env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] != nil,
      "Prepare the large-table fixture on this exact disposable simulator first.")
    try XCTSkipIf(env["LIFE_UI_TEST_TABLE_NAV_HUB"] != nil, "Requires the local-only fixture")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    tap(app.buttons["open-local"], app)
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    for _ in 0..<3 {
      tap(app.navigationBars.buttons["BackButton"].firstMatch, app)
      let provenance = app.buttons["sidebar-table-provenance"]
      if !provenance.exists {
        revealSidebar(app.buttons["System tables"], app)
        tap(app.buttons["System tables"], app)
      }
      revealSidebar(provenance, app)
      tap(provenance, app)
      XCTAssertTrue(
        app.navigationBars["provenance"].waitForExistence(timeout: 15), app.debugDescription)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "provenance-open"
      shot.lifetime = .keepAlways
      add(shot)
      tap(app.navigationBars.buttons["BackButton"].firstMatch, app)
      let notes = app.buttons["sidebar-table-notes"]
      revealSidebar(notes, app)
      tap(notes, app)
      XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10), app.debugDescription)
    }
  }

  private func revealSidebar(_ element: XCUIElement, _ app: XCUIApplication) {
    let footer = app.staticTexts.matching(
      NSPredicate(
        format: "label IN %@",
        [
          "Hub workspace · local replica", "Local workspace · saved on this device",
        ])
    ).firstMatch
    for _ in 0..<8 {
      if element.exists {
        let frame = element.frame
        if frame.minY < app.navigationBars.firstMatch.frame.maxY {
          app.swipeDown()
        } else if frame.maxY > footer.frame.minY {
          app.swipeUp()
        } else if element.isHittable {
          return
        } else {
          app.swipeUp()
        }
      } else {
        app.swipeUp()
      }
    }
    XCTFail("Sidebar control must be visible above the fixed footer: \(element)")
  }

  private func tap(_ element: XCUIElement, _ app: XCUIApplication) {
    XCTAssertTrue(element.exists || element.waitForExistence(timeout: 10), app.debugDescription)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.isEnabled && element.isHittable }
      }, object: nil)
    if !element.isEnabled || !element.isHittable {
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
    }
    element.tap()
  }
}
