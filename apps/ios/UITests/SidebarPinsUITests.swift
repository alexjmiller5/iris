import XCTest

@MainActor
final class SidebarPinsUITests: XCTestCase {
  func testPinDragReorderAndLongPressUnpinThroughTheSidebar() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    let pinTopics = app.buttons["Pin topics"]
    reveal(pinTopics, in: app)
    pinTopics.tap()
    let topics = app.buttons["sidebar-pinned-topics"]
    XCTAssertTrue(topics.waitForExistence(timeout: 5))
    let pinNotes = app.buttons["Pin notes"]
    reveal(pinNotes, in: app)
    pinNotes.tap()
    let notes = app.buttons["sidebar-pinned-notes"]
    XCTAssertTrue(notes.waitForExistence(timeout: 5))
    reveal(topics, in: app)
    XCTAssertLessThan(topics.frame.minY, notes.frame.minY)
    XCTAssertFalse(app.buttons["sidebar-table-notes"].exists)
    XCTAssertFalse(app.buttons["sidebar-table-topics"].exists)
    // Drag the three-bar handle (trailing in the row) above topics.
    let row = app.cells.containing(.button, identifier: "sidebar-pinned-notes").firstMatch
    let handle = row.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: -28, dy: 0))
    handle.press(
      forDuration: 0.05,
      thenDragTo: topics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
      withVelocity: .slow, thenHoldForDuration: 0.3)
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        notes.exists && topics.exists && notes.frame.minY < topics.frame.minY
      },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
    let sidebar = XCTAttachment(screenshot: app.screenshot())
    sidebar.name = "reordered-sidebar-pins"
    sidebar.lifetime = .keepAlways
    add(sidebar)
    // A long press opens the row's menu; its destructive item unpins.
    notes.press(forDuration: 1.2)
    let unpin = app.buttons["Unpin"]
    XCTAssertTrue(unpin.waitForExistence(timeout: 5))
    let menu = XCTAttachment(screenshot: app.screenshot())
    menu.name = "pin-long-press-menu"
    menu.lifetime = .keepAlways
    add(menu)
    unpin.tap()
    XCTAssertTrue(app.buttons["sidebar-table-notes"].waitForExistence(timeout: 5))
    XCTAssertFalse(notes.exists)
    reveal(topics, in: app)
    topics.tap()
    XCTAssertTrue(app.navigationBars["topics"].waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "pinned-table-opened"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<5 {
      if element.exists && element.isHittable { return }
      if element.exists && element.frame.maxY < app.frame.midY {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
  }
}
