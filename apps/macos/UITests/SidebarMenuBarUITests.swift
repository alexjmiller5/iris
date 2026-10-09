import XCTest

/// Sample workspace: Cmd+\ and View > Toggle Sidebar hide and restore the sidebar,
/// the choice survives relaunch, and the menu-bar item mirrors the sync pill.
@MainActor
final class SidebarMenuBarUITests: XCTestCase {
  func testCommandBackslashTogglesPersistedSidebarAndMenuBarItemOpensQuickFind() throws {
    continueAfterFailure = false
    var app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    let pill = app.buttons["workspace-status"]
    XCTAssertTrue(app.buttons["new-record"].waitForExistence(timeout: 15))
    // A previous run may have left the sidebar hidden; start from the visible state.
    if !visible(pill) { app.typeKey("\\", modifierFlags: .command) }
    XCTAssertTrue(wait(pill, visible: true))
    XCTAssertEqual(pill.label, "Local only")
    XCTAssertFalse(app.buttons["sync-now"].exists)
    capture("mac-sidebar-visible")

    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(wait(pill, visible: false), "Cmd+\\ hides the sidebar")
    capture("mac-sidebar-hidden")
    app.menuBars.menuBarItems["View"].click()
    app.menuItems["Toggle Sidebar"].click()
    XCTAssertTrue(wait(pill, visible: true), "View > Toggle Sidebar restores it")

    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(wait(pill, visible: false))
    app.terminate()
    app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["new-record"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      wait(app.buttons["workspace-status"], visible: false), "The hidden sidebar persists")
    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(wait(app.buttons["workspace-status"], visible: true))

    let item = app.descendants(matching: .statusItem).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "The menu-bar item is shown by default")
    item.click()
    XCTAssertTrue(app.menuItems["Open Iris"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["Local only"].exists, "The menu mirrors the sync pill")
    XCTAssertTrue(app.menuItems["Quit Iris"].exists)
    capture("mac-menu-bar-item")
    app.menuItems["Quick Find…"].click()
    XCTAssertTrue(
      app.textFields["quick-find-query"].waitForExistence(timeout: 10),
      "Quick Find from the menu bar opens in the window")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// A collapsed column may keep its views offscreen; hit-testing is what users see.
  private func visible(_ element: XCUIElement) -> Bool { element.exists && element.isHittable }

  private func wait(_ element: XCUIElement, visible: Bool) -> Bool {
    let predicate =
      visible
      ? NSPredicate(format: "exists == true AND hittable == true")
      : NSPredicate(format: "exists == false OR hittable == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  private func capture(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
