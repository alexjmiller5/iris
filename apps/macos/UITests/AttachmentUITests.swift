import XCTest

@MainActor final class AttachmentUITests: XCTestCase {
  func testOfflineAttachmentPickerIsMountedInMarkdown() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    defer { app.terminate() }
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    let grid = app.descendants(matching: .any).matching(identifier: "record-grid").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 15))
    let header = grid.buttons.matching(NSPredicate(format: "title == %@", "Body")).firstMatch
    let title = grid.staticTexts.matching(NSPredicate(format: "value == %@", "A place to start"))
      .firstMatch
    XCTAssertTrue(header.exists)
    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 0, dy: title.frame.midY - header.frame.midY)).doubleClick()
    XCTAssertTrue(grid.webViews.textViews["Body"].waitForExistence(timeout: 10))
    let attach = grid.buttons["markdown-attach-file"]
    XCTAssertTrue(attach.waitForExistence(timeout: 3))
    attach.click()
    let cancel = app.buttons["CancelButton"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.click()
    XCTAssertTrue(attach.isEnabled)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "attachment-ui-" + UUID().uuidString + ".txt")
    try Data("exact native synthetic bytes ☃".utf8).write(to: file)
    print("Attachment fixture: " + file.lastPathComponent)
    defer { try? FileManager.default.removeItem(at: file) }
    attach.click()
    XCTAssertTrue(app.buttons["CancelButton"].waitForExistence(timeout: 5))
    let search = app.searchFields["Search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeKey("g", modifierFlags: [.command, .shift])
    let path = app.textFields["PathTextField"]
    XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
    path.click()
    path.typeKey("a", modifierFlags: [.command])
    path.typeText(file.path)
    path.typeKey(.return, modifierFlags: [])
    let open = app.buttons["OKButton"].firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(open))
    open.click()
    XCTAssertTrue(grid.staticTexts["1 file(s) pending"].waitForExistence(timeout: 10))
    XCTAssertFalse(
      grid.buttons["Retry uploads"].isEnabled, "A demo with no enrolled hub cannot retry uploads")
    let options = grid.webViews.descendants(matching: .any)["Body options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.click()
    grid.webViews.descendants(matching: .any)["Body source"].click()
    let source = grid.webViews.textViews["Body"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    let stored = source.value as? String ?? ""
    XCTAssertTrue(stored.contains(file.lastPathComponent))
    XCTAssertTrue(stored.contains("/v1/files/attachments/"))
    let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    image.name = "offline-native-attachment"
    image.lifetime = .keepAlways
    add(image)
  }
  private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }
}
