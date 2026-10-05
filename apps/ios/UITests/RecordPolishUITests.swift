import XCTest

@MainActor
final class RecordPolishUITests: XCTestCase {
  func testInlineTitleSaveAndPopupKeepTheSameDraft() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    let edit = app.buttons["inline-property-title"].firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    XCTAssertTrue(app.otherElements["inline-record-editor"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Record"].exists)
    XCTAssertFalse(
      app.navigationBars.buttons["BackButton"].firstMatch.exists,
      "Finish the inline draft before leaving the detail column")
    let title = app.textFields["field-title"]
    title.tap()
    title.typeText("Inline ")
    let inlineDraft = title.value as? String
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
      .press(
        forDuration: 0.1,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
    XCTAssertTrue(app.buttons["inline-save"].exists)
    XCTAssertEqual(title.value as? String, inlineDraft)
    capture(app, "inline-property-editor")
    app.buttons["inline-save"].tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    XCTAssertEqual(edit.value as? String, inlineDraft)
    edit.tap()
    title.tap()
    title.typeText("Popup with a longer property value that should wrap across lines ")
    let draft = title.value as? String
    app.buttons["inline-open-record"].tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, draft)
    XCTAssertGreaterThan(title.frame.height, 40, "Long properties must wrap instead of clipping")
    app.buttons["save-record"].tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    XCTAssertEqual(edit.value as? String, draft)
    edit.tap()
    title.tap()
    title.typeText("Discard ")
    app.buttons["inline-cancel"].tap()
    if app.buttons["Keep editing"].exists {
      app.buttons["Keep editing"].tap()
    } else {
      app.otherElements["PopoverDismissRegion"].tap()
    }
    XCTAssertTrue(app.buttons["inline-save"].exists)
    app.buttons["inline-cancel"].tap()
    app.buttons["Discard changes"].tap()
    XCTAssertEqual(edit.value as? String, draft)
    let status = app.buttons["inline-property-status"]
    status.tap()
    app.buttons["field-status"].tap()
    app.buttons["Ready"].tap()
    app.buttons["inline-save"].tap()
    XCTAssertTrue(status.label.contains("Ready"))
    XCTAssertFalse(status.label.contains("Draft"))
    capture(app, "inline-save-and-popup-draft")
  }

  func testEmptyPropertiesExpandWithoutMovingAnEditedFieldAndSave() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 15))
    let record = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "A place to start")
    ).firstMatch
    record.tap()
    XCTAssertTrue(app.textFields["field-title"].waitForExistence(timeout: 5))
    let empty = app.collectionViews["record-form"].staticTexts["Empty properties"]
    XCTAssertTrue(empty.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["field-topic"].exists)
    capture(app, "empty-properties-collapsed")
    empty.tap()
    let topic = app.buttons["field-topic"]
    for _ in 0..<5 where !topic.isHittable { app.swipeUp() }
    topic.tap()
    app.buttons["Field notes"].tap()
    XCTAssertTrue(app.navigationBars["Record"].waitForExistence(timeout: 5))
    for _ in 0..<5 where !empty.isHittable { app.swipeDown() }
    empty.tap()
    XCTAssertFalse(topic.exists, "An edited field must stay in its disclosure until reopening")
    app.buttons["save-record"].tap()
    let referenceLabel = app.buttons["inline-property-topic"]
    XCTAssertTrue(referenceLabel.waitForExistence(timeout: 5))
    XCTAssertTrue(
      referenceLabel.label.contains("Field notes"), "Show the related title, not its opaque ID")
    record.tap()
    XCTAssertTrue(topic.waitForExistence(timeout: 5))
    XCTAssertTrue(topic.label.contains("Field notes"))
    capture(app, "filled-property-visible-after-reopening")
  }

  func testReadOnlyPropertiesStayVisibleAndReferenceStillOpens() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] != nil
        && env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] == env["SIMULATOR_UDID"],
      "Use the explicitly selected synthetic simulator fixture.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-local"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    app.buttons["System tables"].tap()
    let table = app.buttons["sidebar-table-readonly_notes"]
    for _ in 0..<8 where !table.isHittable { app.swipeUp() }
    table.tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read-only title"))
      .firstMatch.tap()
    XCTAssertTrue(app.staticTexts["record-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["record-heading"].label, "Read-only title")
    XCTAssertTrue(app.staticTexts["Visible read-only detail"].isHittable)
    XCTAssertFalse(app.staticTexts["opaque-fixture-record"].exists)
    capture(app, "read-only-title-and-properties")
    let reference = app.buttons["Open Linked fixture topic"]
    XCTAssertTrue(reference.waitForExistence(timeout: 5))
    reference.tap()
    XCTAssertTrue(app.staticTexts["record-heading"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["record-heading"].label, "Linked fixture topic")
  }

  func testRulesAreBottomLinkAndReturningPreservesDraft() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] != nil
        && env["LIFE_UI_TEST_RECORD_POLISH_SIMULATOR"] == env["SIMULATOR_UDID"],
      "Use the explicitly selected synthetic simulator fixture.")
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    app.launch()
    defer { app.terminate() }
    app.buttons["open-local"].tap()
    XCTAssertTrue(app.navigationBars["notes"].waitForExistence(timeout: 10))
    capture(app, "record-list-before-opening")
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A place to start"))
      .firstMatch.tap()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    capture(app, "record-open-before-rules")
    XCTAssertTrue(title.isHittable, "Catalog rules must not push the title offscreen")
    XCTAssertLessThan(title.frame.minY, app.frame.height * 0.5)
    title.tap()
    title.typeText(" retained draft")
    let draft = title.value as? String
    let rules = app.buttons["catalog-rules"]
    for _ in 0..<12 where !rules.isHittable { app.swipeUp() }
    XCTAssertTrue(rules.isHittable)
    rules.tap()
    XCTAssertTrue(app.navigationBars["Catalog rules"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Keep a useful record title.")
      ).firstMatch.exists)
    capture(app, "record-catalog-rules-page")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    for _ in 0..<12 where !title.isHittable { app.swipeDown() }
    XCTAssertEqual(title.value as? String, draft)
    capture(app, "record-draft-after-rules")
    app.navigationBars.buttons["Cancel"].tap()
    app.buttons["Discard changes"].tap()
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
