import XCTest

@MainActor
final class InlineMarkdownUITests: XCTestCase {
  func testFullRecordWritesContentBelowPropertiesWithoutAnotherPage() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    let open = app.buttons["A place to start, Open record"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    open.tap()
    let rich = app.webViews.textViews["Body"]
    XCTAssertTrue(rich.waitForExistence(timeout: 10), "Content must be editable on the record page")
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.exists)
    XCTAssertLessThan(title.frame.minY, rich.frame.minY)
    for _ in 0..<5 where !rich.isHittable { app.swipeUp() }
    rich.tap()
    rich.typeText(" Full page final input")
    app.navigationBars["Record"].buttons["done-record"].tap()
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    open.tap()
    XCTAssertTrue(rich.waitForExistence(timeout: 10))
    XCTAssertTrue((rich.value as? String ?? "").contains("Full page final input"))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "full-record-content"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testRichContentEditsInTheListAndExpandsWithoutLosingTheDraft() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    app.buttons["inline-property-body"].tap()
    let rich = app.webViews.textViews["Body"]
    XCTAssertTrue(rich.waitForExistence(timeout: 10))
    XCTAssertFalse(app.navigationBars["Record"].exists)
    rich.tap()
    rich.typeText("# Mobile heading\n\n- Mobile item")
    let editor = app.descendants(matching: .any)["inline-record-editor"]
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in (editor.value as? String) == "Saved on this device" },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    XCTAssertFalse(
      app.buttons["undo-saved-change"].exists,
      "Autosave must not insert a row above the active editor and move its actions")
    let expand = app.buttons["inline-open-record"]
    for _ in 0..<5 where !expand.isHittable { app.swipeUp() }
    XCTAssertTrue(expand.isHittable)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "mobile-inline-markdown"
    shot.lifetime = .keepAlways
    add(shot)
    expand.tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.webViews.textViews["Body"].waitForExistence(timeout: 10))
    let options = app.webViews.descendants(matching: .any)["Body options"]
    if options.waitForExistence(timeout: 2) { options.tap() }
    let sourceButton = app.webViews.descendants(matching: .any)["Body source"]
    XCTAssertTrue(sourceButton.waitForExistence(timeout: 5))
    sourceButton.tap()
    let source = app.webViews.textViews["Body"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    let value = source.value as? String ?? ""
    XCTAssertTrue(value.contains("Mobile heading"))
    XCTAssertTrue(value.contains("Mobile item"))
  }

  func testEmptyContentFormatsHeadingAndListUsingThePhoneKeyboard() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    let create = app.navigationBars["notes"].buttons["new-record"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    create.tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Markdown keyboard fixture")
    app.navigationBars["New record"].buttons["done-record"].tap()
    let row = app.cells.containing(.button, identifier: "Markdown keyboard fixture, Open record")
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    let before = XCTAttachment(screenshot: app.screenshot())
    before.name = "empty-content-before-disclosure"
    before.lifetime = .keepAlways
    add(before)
    let hierarchy = XCTAttachment(string: row.debugDescription)
    hierarchy.name = "empty-content-row"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    row.staticTexts["Empty properties"].tap()
    let content = row.buttons["inline-property-body"]
    XCTAssertTrue(content.waitForExistence(timeout: 5))
    content.tap()
    let rich = app.webViews.textViews["Body"]
    XCTAssertTrue(rich.waitForExistence(timeout: 10))
    rich.tap()
    rich.typeText("# Mobile heading\n\n- Mobile item")
    let expand = app.buttons["inline-open-record"]
    XCTAssertTrue(expand.isHittable)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "mobile-markdown-shortcuts"
    shot.lifetime = .keepAlways
    add(shot)
    expand.tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.webViews.textViews["Body"].waitForExistence(timeout: 10))
    let options = app.webViews.descendants(matching: .any)["Body options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.tap()
    app.webViews.descendants(matching: .any)["Body source"].tap()
    let source = app.webViews.textViews["Body"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    let value = source.value as? String ?? ""
    XCTAssertTrue(value.hasPrefix("# Mobile heading"))
    XCTAssertTrue(value.contains("- Mobile item") || value.contains("* Mobile item"))
  }
}
