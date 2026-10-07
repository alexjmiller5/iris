import XCTest

@MainActor
final class SidebarPinsUITests: XCTestCase {
  func testPinOrderMoveAndUnpinThroughTheSidebar() throws {
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
    app.buttons["Pin actions for notes"].tap()
    app.buttons["Move up"].tap()
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
    app.buttons["Pin actions for notes"].tap()
    app.buttons["Unpin"].tap()
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
