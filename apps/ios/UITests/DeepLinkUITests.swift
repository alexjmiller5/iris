import UIKit
import XCTest

/// Run only on an explicitly selected disposable simulator. Uses real local SQLite,
/// system URL delivery and the clipboard; it never injects a navigation result.
@MainActor
final class DeepLinkUITests: XCTestCase {
  private func application() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard let selected = environment["LIFE_UI_TEST_LINK_SIMULATOR"], !selected.isEmpty,
      UUID(uuidString: selected) != nil, selected == environment["SIMULATOR_UDID"]
    else { throw XCTSkip("Select this exact disposable SIMULATOR_UDID for native link tests.") }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    return app
  }

  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { element.isHittable && element.isEnabled }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }

  /// The shared simulator workspace can hold other fixture tables; use the sample notes.
  private func openNotes(_ app: XCUIApplication) {
    if app.navigationBars["notes"].waitForExistence(timeout: 3) { return }
    tap(app.navigationBars.buttons["BackButton"].firstMatch)
    tap(app.buttons["sidebar-table-notes"])
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
  }

  private func copy(_ button: XCUIElement) {
    // Writing needs no paste permission; the sentinel proves the next copy happened.
    UIPasteboard.general.string = "clipboard sentinel"
    tap(button)
  }

  /// Reads the clipboard through the app's own Quick Find field with the OS Paste
  /// menu, as a user would. The runner itself cannot read another app's clipboard.
  private func pastedURL(_ app: XCUIApplication) throws -> URL {
    tap(app.buttons["quick-find"])
    let query = app.textFields["quick-find-query"]
    tap(query)
    query.press(forDuration: 1.2)
    tap(app.menuItems["Paste"].firstMatch)
    let pasted = try XCTUnwrap(query.value as? String)
    XCTAssertTrue(pasted.hasPrefix("life://open/v1?"), pasted)
    tap(app.navigationBars["Quick Find"].buttons["Cancel"])
    XCTAssertTrue(query.waitForNonExistence(timeout: 5))
    return try XCTUnwrap(URL(string: pasted))
  }

  func testCopyAndColdURLRemainPendingUntilTheMatchingLocalWorkspaceIsOpened() throws {
    let app = try application()
    tap(app.buttons["open-local"])
    openNotes(app)
    copy(app.buttons["copy-workspace-link"])
    let url = try pastedURL(app)
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(Set(items.map(\.name)), ["local", "table"])
    XCTAssertEqual(items.first { $0.name == "table" }?.value, "notes")
    app.terminate()
    // XCUIApplication.open launches the app by URL; running-app delivery uses the system.
    app.open(url)
    XCTAssertTrue(app.buttons["open-local"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["open-pending-link"].exists)
    XCTAssertFalse(app.buttons["open-pending-link"].isEnabled)
    tap(app.buttons["open-local"])
    XCTAssertTrue(
      app.buttons["open-pending-link"].exists,
      "Opening a workspace must not autoactivate the pending URL")
    tap(app.buttons["open-pending-link"])
    XCTAssertTrue(app.buttons["open-pending-link"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.navigationBars["notes"].exists)
    copy(app.buttons["copy-workspace-link"])
    XCTAssertEqual(try pastedURL(app), url)
  }

  func testIncomingRecordLinkKeepsDirtyEditorAndCancelledDiscardUntilExplicitOpen() throws {
    let app = try application()
    tap(app.buttons["open-local"])
    openNotes(app)
    tap(app.buttons["new-record"])
    // Older unsaved new-record drafts on this workspace are offered first; start fresh.
    let fresh = app.buttons["Start new record"]
    if fresh.waitForExistence(timeout: 3) { tap(fresh) }
    let title = app.textFields["field-title"]
    tap(title)
    let name = "Link fixture " + UUID().uuidString
    title.typeText(name)
    tap(app.buttons["save-record"])
    // Other fixture rows can sort ahead of this one; filter before opening it.
    let search = app.searchFields.firstMatch
    tap(search)
    // Submitting dismisses the keyboard so the bottom search bar no longer covers the row.
    search.typeText(name + "\n")
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    tap(row)
    copy(app.buttons["copy-record-link"])
    tap(app.navigationBars["Record"].buttons["Cancel"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))
    let url = try pastedURL(app)
    tap(row)
    tap(title)
    title.typeText(" unsaved")
    let draft = try XCTUnwrap(title.value as? String)
    XCUIDevice.shared.system.open(url)
    XCTAssertTrue(app.staticTexts["link-waiting-editor"].waitForExistence(timeout: 10))
    XCTAssertEqual(title.value as? String, draft)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    let confirmation = app.sheets["Discard unsaved changes?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    // iOS presents this confirmation as a popover; tapping outside keeps editing.
    let outside = app.navigationBars["Record"].staticTexts["Record"]
    XCTAssertFalse(confirmation.frame.intersects(outside.frame))
    outside.tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, draft)
    XCTAssertTrue(app.staticTexts["link-waiting-editor"].exists)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    tap(app.buttons["Discard changes"])
    XCTAssertTrue(app.buttons["open-pending-link"].waitForExistence(timeout: 10))
    tap(app.buttons["open-pending-link"])
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    XCTAssertEqual(title.value as? String, name)
    XCTAssertFalse(app.staticTexts["link-waiting-editor"].exists)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    XCTAssertTrue(app.navigationBars["Record"].waitForNonExistence(timeout: 10))

    // Receipt while idle still waits for an explicit Open.
    XCUIDevice.shared.system.open(url)
    XCTAssertTrue(app.buttons["open-pending-link"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.navigationBars["Record"].waitForExistence(timeout: 3))
    tap(app.buttons["dismiss-pending-link"])
    XCTAssertTrue(app.buttons["open-pending-link"].waitForNonExistence(timeout: 5))

    var wrong = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    wrong.queryItems = wrong.queryItems?.map {
      $0.name == "local" ? URLQueryItem(name: "local", value: UUID().uuidString) : $0
    }
    XCUIDevice.shared.system.open(try XCTUnwrap(wrong.url))
    tap(app.buttons["open-pending-link"])
    XCTAssertTrue(app.staticTexts["pending-link-error"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["open-pending-link"].exists)
    XCTAssertFalse(app.navigationBars["Record"].exists)
    tap(app.buttons["dismiss-pending-link"])
  }
}
