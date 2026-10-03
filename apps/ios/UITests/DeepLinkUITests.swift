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
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      MainActor.assumeIsolated { element.isHittable && element.isEnabled }
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    element.tap()
  }

  private func copiedURL(_ button: XCUIElement) throws -> URL {
    UIPasteboard.general.string = "clipboard sentinel"
    tap(button)
    let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      MainActor.assumeIsolated { UIPasteboard.general.string?.hasPrefix("life://open/v1?") == true }
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 10), .completed)
    return try XCTUnwrap(URL(string: try XCTUnwrap(UIPasteboard.general.string)))
  }

  func testCopyAndColdURLRemainPendingUntilTheMatchingLocalWorkspaceIsOpened() throws {
    let app = try application()
    tap(app.buttons["open-local"])
    let url = try copiedURL(app.buttons["copy-workspace-link"])
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(Set(items.map(\.name)), ["local", "table"])
    XCTAssertEqual(items.first { $0.name == "table" }?.value, "notes")
    app.terminate()
    app.open(url)
    XCTAssertTrue(app.buttons["open-local"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["open-pending-link"].exists)
    XCTAssertFalse(app.buttons["open-pending-link"].isEnabled)
    tap(app.buttons["open-local"])
    XCTAssertTrue(app.buttons["open-pending-link"].exists, "Opening a workspace must not autoactivate the pending URL")
    tap(app.buttons["open-pending-link"])
    XCTAssertTrue(app.buttons["open-pending-link"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.navigationBars["notes"].exists)
    XCTAssertEqual(try copiedURL(app.buttons["copy-workspace-link"]), url)
  }

  func testIncomingRecordLinkKeepsDirtyEditorAndCancelledDiscardUntilExplicitOpen() throws {
    let app = try application()
    tap(app.buttons["open-local"])
    tap(app.buttons["new-record"])
    let title = app.textFields["field-title"]
    tap(title)
    let name = "Link fixture " + UUID().uuidString
    title.typeText(name)
    tap(app.buttons["save-record"])
    tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch)
    let url = try copiedURL(app.buttons["copy-record-link"])
    tap(title)
    title.typeText(" unsaved")
    let draft = try XCTUnwrap(title.value as? String)
    app.open(url)
    XCTAssertTrue(app.staticTexts["link-waiting-editor"].waitForExistence(timeout: 10))
    XCTAssertEqual(title.value as? String, draft)
    tap(app.navigationBars["Record"].buttons["Cancel"])
    tap(app.buttons["Keep editing"])
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

    var wrong = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    wrong.queryItems = wrong.queryItems?.map { $0.name == "local" ? URLQueryItem(name: "local", value: UUID().uuidString) : $0 }
    app.open(try XCTUnwrap(wrong.url))
    tap(app.buttons["open-pending-link"])
    XCTAssertTrue(app.staticTexts["pending-link-error"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["open-pending-link"].exists)
    XCTAssertFalse(app.navigationBars["Record"].exists)
    tap(app.buttons["dismiss-pending-link"])
  }
}
