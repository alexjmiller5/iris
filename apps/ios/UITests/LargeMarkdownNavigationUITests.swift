import XCTest

@MainActor
final class LargeMarkdownNavigationUITests: XCTestCase {
  func testLargeMarkdownNotesOpenAndReturnToSidebarPromptly() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_MARKDOWN_NAV_SIMULATOR"] == env["SIMULATOR_UDID"]
        && env["LIFE_UI_TEST_MARKDOWN_NAV_SIMULATOR"] != nil,
      "Prepare the synthetic large Markdown fixture on this exact disposable simulator.")
    continueAfterFailure = false
    let endpoint = env["LIFE_UI_TEST_MARKDOWN_NAV_HUB"]
    if let endpoint {
      XCTAssertEqual(URL(string: endpoint)?.host, "127.0.0.1")
      _ = try await gate(endpoint, "hold")
      addTeardownBlock { _ = try await Self.controlGate(endpoint, "release") }
    }
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    let startup = Date()
    if endpoint == nil {
      XCTAssertTrue(app.buttons["open-local"].waitForExistence(timeout: 10))
      app.buttons["open-local"].tap()
    }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 60))
    let first = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "open-record-markdown-nav-")
    ).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 60))
    record("startup_visible_records", since: startup)
    if let endpoint {
      var waiting = false
      for _ in 0..<100 {
        waiting = try await gate(endpoint, "status")
        if waiting { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertTrue(waiting, "The real sync HTTP request must be held before navigating")
    }
    for pass in 0..<(endpoint == nil ? 3 : 1) {
      // Recycle populated reference cells before leaving the table, including
      // a reference whose label request returns a large Markdown source row.
      app.swipeUp()
      app.swipeUp()
      let back = app.navigationBars.buttons["BackButton"].firstMatch
      XCTAssertTrue(back.exists && back.isHittable)
      let returnStart = Date()
      back.tap()
      let notes = app.buttons["sidebar-table-notes"]
      XCTAssertTrue(notes.waitForExistence(timeout: 15))
      record("sidebar_\(pass)", since: returnStart)
      let topics = app.buttons["sidebar-table-topics"]
      XCTAssertTrue(topics.exists && topics.isEnabled && topics.isHittable)
      let topicsStart = Date()
      topics.tap()
      XCTAssertTrue(app.navigationBars["topics"].waitForExistence(timeout: 10))
      record("topics_committed_\(pass)", since: topicsStart)
      back.tap()
      XCTAssertTrue(notes.waitForExistence(timeout: 15))
      XCTAssertTrue(notes.isEnabled && notes.isHittable)
      let start = Date()
      notes.tap()
      XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 60))
      record("notes_committed_\(pass)", since: start)
      XCTAssertTrue(first.waitForExistence(timeout: 60))
      let elapsed = record("notes_visible_records_\(pass)", since: start)
      XCTAssertFalse(app.buttons["cancel-destination"].exists)
      if let endpoint {
        let waiting = try await gate(endpoint, "status")
        XCTAssertTrue(waiting, "Notes must open before the held sync response is released")
        app.buttons["workspace-status"].tap()
        XCTAssertTrue(app.buttons["cancel-sync"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync-now"].isEnabled)
        app.buttons["status-done"].tap()
      }
      if pass == 0 {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "large-markdown-notes-visible"
        shot.lifetime = .keepAlways
        add(shot)
      }
      XCTAssertLessThan(
        elapsed, 10, "A cached 100-row Notes page must not strand the user on Opening")
    }
  }

  @discardableResult
  private func record(_ name: String, since start: Date) -> TimeInterval {
    let elapsed = Date().timeIntervalSince(start)
    let text = "MARKDOWN_NAV \(name)_seconds=\(elapsed)"
    print(text)
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    return elapsed
  }

  private func gate(_ endpoint: String, _ action: String) async throws -> Bool {
    try await Self.controlGate(endpoint, action)
  }

  nonisolated private static func controlGate(_ endpoint: String, _ action: String) async throws
    -> Bool
  {
    let (data, _) = try await URLSession.shared.data(
      from: XCTUnwrap(URL(string: endpoint + "/fixture/" + action)))
    return (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["waiting"] ?? false
  }
}
