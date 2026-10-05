import XCTest

@MainActor
final class TableNavigationUITests: XCTestCase {
  func testQueuedTableNavigationCanBeCancelledWithoutClosingWorkspace() async throws {
    try await exerciseQueuedNavigation(replaceBeforeSyncFinishes: false)
  }

  func testNewNavigationReplacesCancelledRequestWhileSyncContinues() async throws {
    try await exerciseQueuedNavigation(replaceBeforeSyncFinishes: true)
  }

  private func exerciseQueuedNavigation(replaceBeforeSyncFinishes: Bool) async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] == env["SIMULATOR_UDID"]
        && env["LIFE_UI_TEST_TABLE_NAV_SIMULATOR"] != nil,
      "Use only the explicitly selected disposable simulator.")
    try XCTSkipIf(
      env["LIFE_UI_TEST_TABLE_NAV_HUB"] == nil, "Requires the loopback sync gate fixture")
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
    XCTAssertTrue(waiting, "A real sync request must hold the serialized workspace")
    tap(app.navigationBars.buttons["BackButton"].firstMatch, app)
    revealSidebar(app.buttons["System tables"], app)
    tap(app.buttons["System tables"], app)
    let provenance = app.buttons["sidebar-table-provenance"]
    revealSidebar(provenance, app)
    tap(provenance, app)
    XCTAssertTrue(
      app.descendants(matching: .any)["Opening destination…"].firstMatch.waitForExistence(
        timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "queued-provenance-navigation"
    shot.lifetime = .keepAlways
    add(shot)
    let notes = app.buttons["sidebar-table-notes"]
    XCTAssertFalse(
      notes.isEnabled, "Reproduce the disabled sidebar while fresh catalog waits for sync")
    tap(app.buttons["cancel-destination"], app)
    XCTAssertTrue(
      notes.isEnabled, "Cancellation must release navigation without closing the workspace")
    XCTAssertFalse(app.buttons["sync-now"].isEnabled, "Cancel must not stop sync")
    let stillWaiting = try await gate("status")
    XCTAssertTrue(stillWaiting, "The original sync request must remain active")
    XCTAssertFalse(app.buttons["cancel-destination"].exists)
    let recovered = XCTAttachment(screenshot: app.screenshot())
    recovered.name = "navigation-cancelled-sync-continues"
    recovered.lifetime = .keepAlways
    add(recovered)
    if replaceBeforeSyncFinishes {
      revealSidebar(notes, app)
      tap(notes, app)
      XCTAssertTrue(app.buttons["cancel-destination"].waitForExistence(timeout: 5))
      XCTAssertFalse(notes.isEnabled, "New navigation owns the opening state")
    }
    _ = try await gate("release")
    if replaceBeforeSyncFinishes {
      XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
      XCTAssertFalse(app.navigationBars["provenance"].exists)
      XCTAssertFalse(app.buttons["cancel-destination"].exists)
      XCTAssertTrue(app.buttons["quick-find"].isEnabled, "New request must release its controls")
      return
    }
    let finished = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { app.buttons["sync-now"].isEnabled }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
    let stayedInSidebar = app.navigationBars["Life UI"].exists
    XCTAssertTrue(stayedInSidebar, "Cancelled destination must stay closed after sync")
    guard stayedInSidebar else { return }
    revealSidebar(notes, app)
    tap(notes, app)
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    XCTAssertFalse(
      app.navigationBars["provenance"].exists,
      "Late completion must not install cancelled navigation")
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
