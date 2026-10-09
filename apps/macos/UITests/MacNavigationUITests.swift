import AppKit
import XCTest

/// Opt-in: opens the local workspace in this Mac's Application Support folder.
/// Key events go through the window server, so Cmd+K and Return are real input.
@MainActor
final class MacNavigationUITests: XCTestCase {
  func testCommandKReturnAndReceivedLinkStayInTheOpenWindow() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["IRIS_TEST_MAC_LOCAL"] != "1",
      "Set IRIS_TEST_MAC_LOCAL=1 to use this Mac's local workspace.")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    let openLocal = app.buttons["open-local"]
    XCTAssertTrue(openLocal.waitForExistence(timeout: 15))
    openLocal.click()
    XCTAssertTrue(app.buttons["copy-workspace-link"].waitForExistence(timeout: 15))

    app.typeKey("k", modifierFlags: .command)
    let query = app.textFields["quick-find-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 5), "Cmd+K opens Find")
    query.typeText("topics")
    XCTAssertTrue(
      app.descendants(matching: .any)["quick-find-table-topics"].waitForExistence(timeout: 10))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 10), "Return activates the selection")
    let topics = app.buttons["sidebar-table-topics"]
    XCTAssertTrue(topics.isSelected)

    // Read the copied link back through the app's own field, as a user pastes it.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("clipboard sentinel", forType: .string)
    app.buttons["copy-workspace-link"].click()
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    query.click()
    app.typeKey("v", modifierFlags: .command)
    let pasted = try XCTUnwrap(query.value as? String)
    XCTAssertTrue(pasted.hasPrefix("iris://open/v1?") && pasted.contains("table=topics"), pasted)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 5))

    app.buttons["sidebar-table-notes"].click()
    let windows = app.windows.count
    NSWorkspace.shared.open(try XCTUnwrap(URL(string: pasted)))
    let open = app.buttons["open-pending-link"]
    XCTAssertTrue(open.waitForExistence(timeout: 10), "The running app receives the link")
    XCTAssertEqual(app.windows.count, windows, "The open window keeps the link")
    XCTAssertFalse(topics.isSelected, "Receiving a link never navigates by itself")
    open.click()
    XCTAssertTrue(open.waitForNonExistence(timeout: 10))
    XCTAssertTrue(topics.isSelected)
  }
}
