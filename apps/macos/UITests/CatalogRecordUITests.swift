import XCTest

@MainActor
final class CatalogRecordUITests: XCTestCase {
  func testCatalogRuleFailureRetainsDraftAndReadOnlyMetadata() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["IRIS_TEST_CATALOG_CLEAN_HOST"] == "1",
      "Use a disposable clean host; normal startup must never inspect an enrolled user's credentials."
    )
    let path = ProcessInfo.processInfo.environment["IRIS_TEST_CATALOG_DATABASE"]
    try XCTSkipUnless(
      path != nil, "Prepare a fresh CatalogRecordAcceptanceTests external fixture first.")
    let file = URL(fileURLWithPath: try XCTUnwrap(path))
    XCTAssertEqual(file.lastPathComponent, "catalog-acceptance.sqlite")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 3) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    defer { app.terminate() }
    // Use the supported external-file picker, never replace the app's local replica.
    let open = app.buttons["Open a local database…"]
    XCTAssertTrue(
      open.waitForExistence(timeout: 10),
      "Allocate a clean app instance; never close another workspace or draft")
    open.click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.sheets.textFields.firstMatch
    XCTAssertTrue(location.waitForExistence(timeout: 5))
    location.typeText(file.path)
    location.typeKey(.return, modifierFlags: [])
    let confirmOpen = app.sheets.buttons["Open"].firstMatch
    XCTAssertTrue(confirmOpen.waitForExistence(timeout: 5))
    confirmOpen.click()
    let table = app.buttons["sidebar-table-record_examples"]
    XCTAssertTrue(table.waitForExistence(timeout: 10))
    table.click()
    let record = app.buttons["Open Catalog fixture"]
    XCTAssertTrue(record.waitForExistence(timeout: 5))
    record.click()
    let title = app.textFields["field-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertTrue(app.images["Required"].exists)
    app.buttons["About Title"].click()
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "value CONTAINS %@ OR label CONTAINS %@", "Short fixture title.",
          "Short fixture title.")
      ).firstMatch.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    let state = app.popUpButtons["field-state"]
    XCTAssertTrue(state.exists)
    state.click()
    // Menu rows show the option value; its description stays in the field help.
    let ready = app.menuItems.matching(NSPredicate(format: "title == %@", "Ready")).firstMatch
    XCTAssertTrue(ready.waitForExistence(timeout: 5))
    ready.click()
    for text in ["Immutable fixture value", "Derived fixture value"] {
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
        ).firstMatch.exists)
    }
    XCTAssertFalse(app.textFields["field-locked"].exists)
    XCTAssertFalse(app.textFields["field-computed"].exists)
    capture(app, "catalog-metadata")
    replace(title, with: "Blocked")
    let detail = app.textFields["field-detail"]
    XCTAssertTrue(detail.isHittable)
    detail.click()
    // Leaving the title saves it; the refusal lands while Detail has focus and must keep it.
    XCTAssertTrue(app.buttons["Retry saving"].waitForExistence(timeout: 10))
    detail.typeKey("a", modifierFlags: .command)
    detail.typeText("Retained second edit")
    let form = app.scrollViews["record-form"]
    let rules = app.buttons["catalog-rules"]
    // macOS XCUI click can hit the sheet toolbar when a Form row is clipped.
    form.scroll(byDeltaX: 0, deltaY: -400)
    XCTAssertTrue(rules.isHittable)
    XCTAssertTrue(
      form.frame.contains(rules.frame), "Rules must be visible inside the form before clicking")
    rules.click()
    XCTAssertTrue(app.staticTexts["Fixture title is blocked."].waitForExistence(timeout: 5))
    app.buttons["Back"].firstMatch.click()
    // Autosave meets the rule: the refusal shows inline and the editor stays open.
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "value CONTAINS %@ OR label CONTAINS %@", "Fixture title is blocked.",
          "Fixture title is blocked.")
      ).firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["done-record"].exists, "A refused value must keep the record open")
    XCTAssertEqual(title.value as? String, "Blocked")
    XCTAssertEqual(detail.value as? String, "Retained second edit")
    capture(app, "catalog-rejected-draft")
    form.scroll(byDeltaX: 0, deltaY: 400)
    replace(title, with: "Allowed")
    app.buttons["done-record"].click()
    let saved = app.buttons["Open Allowed"]
    XCTAssertTrue(saved.waitForExistence(timeout: 10))
    saved.click()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, "Allowed")
    XCTAssertEqual(detail.value as? String, "Retained second edit")
    for text in ["Immutable fixture value", "Derived fixture value"] {
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
        ).firstMatch.exists)
    }
    capture(app, "catalog-corrected-readback")
    app.buttons["done-record"].click()
  }

  private func replace(_ field: XCUIElement, with value: String) {
    XCTAssertTrue(field.isHittable)
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(value)
  }

  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
