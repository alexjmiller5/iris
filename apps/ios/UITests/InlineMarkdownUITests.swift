import XCTest

@MainActor
final class InlineMarkdownUITests: XCTestCase {
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
    let expand = app.buttons["inline-open-record"]
    for _ in 0..<5 where !expand.isHittable { app.swipeUp() }
    XCTAssertTrue(expand.isHittable)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "mobile-inline-markdown"
    shot.lifetime = .keepAlways
    add(shot)
    expand.tap()
    let body = app.buttons["field-body"]
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    for _ in 0..<5 where !body.isHittable { app.swipeUp() }
    body.tap()
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
}
