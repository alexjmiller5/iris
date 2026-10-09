import XCTest

/// System entry points against the app's own local workspace on an explicitly
/// owned simulator, after `WidgetRolloverUIFixtureTests` enabled the synthetic
/// sources. Every path ends in an ordinary pending link or draft; nothing saves.
@MainActor final class NativeIntegrationsUITests: XCTestCase {
  private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  private func application() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard let selected = environment["LIFE_UI_TEST_WIDGET_SIMULATOR"],
      selected == environment["SIMULATOR_UDID"]
    else { throw XCTSkip("Select this exact disposable SIMULATOR_UDID for integration tests.") }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--normal-startup"]
    return app
  }

  private func openWorkspace(_ app: XCUIApplication) {
    if app.buttons["open-local"].waitForExistence(timeout: 5) { app.buttons["open-local"].tap() }
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
  }

  /// Hierarchy text for diagnosing system UI that changes between OS releases.
  private func require(_ element: XCUIElement, in app: XCUIApplication, _ timeout: TimeInterval) {
    guard !element.waitForExistence(timeout: timeout) else { return }
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "hierarchy"
    tree.lifetime = .keepAlways
    add(tree)
    keep(app, "missing-element")
    XCTFail("Missing \(element)")
  }

  private func keep(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testDailySectionSitsAboveTablesAndOpensItsRow() throws {
    let app = try application()
    app.launch()
    openWorkspace(app)
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    if back.waitForExistence(timeout: 5) { back.tap() }
    let section = app.buttons["daily-section"]
    XCTAssertTrue(section.waitForExistence(timeout: 15))
    if ProcessInfo.processInfo.environment["LIFE_UI_TEST_DAILY_AFTER_BOUNDARY"] != nil {
      // Rows saved before the configured 03:00 boundary roll out of Today with the app closed.
      XCTAssertTrue(app.staticTexts["No matching records"].waitForExistence(timeout: 15))
      XCTAssertFalse(app.buttons["daily-row"].exists)
      keep(app, "daily-section-after-boundary")
      return
    }
    let row = app.buttons["daily-row"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    let table = app.buttons["sidebar-table-notes"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    XCTAssertLessThan(row.frame.maxY, table.frame.minY)
    keep(app, "daily-section-above-tables")
    let title = row.label
    row.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, title)
    keep(app, "daily-row-opened")
  }

  func testSpotlightTitleOpensItsRowThroughTheLinkBanner() throws {
    let app = try application()
    XCUIDevice.shared.press(.home)
    let pill = springboard.otherElements["spotlight-pill"].firstMatch
    if pill.waitForExistence(timeout: 5) { pill.tap() } else { springboard.swipeDown() }
    // Spotlight's field and results live in their own process on current iOS.
    let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
    let search = spotlight.textFields["SpotlightSearchField"]
    require(search, in: spotlight, 10)
    search.tap()
    // A unique synthetic title saved by the Quick Add acceptance run.
    let title = "Quick Add fixture saved"
    search.typeText(title + "\n")
    // Only Life UI's own Core Spotlight item (under the app's section), never a web
    // suggestion with the same text.
    let header = spotlight.otherElements.matching(
      NSPredicate(format: "identifier BEGINSWITH 'Identifier:SectionHeader' AND identifier ENDSWITH ',Title:Life UI'")
    ).firstMatch
    // Spotlight ingests app items asynchronously; retype until the app's section appears.
    for _ in 0..<6 where !header.waitForExistence(timeout: 20) {
      search.tap()
      let clear = spotlight.buttons["Clear text"]
      if clear.exists { clear.tap() }
      search.typeText(title + "\n")
    }
    require(header, in: spotlight, 5)
    let section = header.identifier.components(separatedBy: ",").first { $0.hasPrefix("Section:") } ?? ""
    let result = spotlight.cells.matching(
      NSPredicate(format: "identifier CONTAINS %@ AND label CONTAINS[c] %@", "ResultCell,\(section),", title)
    ).firstMatch
    require(result, in: spotlight, 20)
    keep(spotlight, "spotlight-title-result")
    result.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    let open = app.buttons["open-pending-link"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    keep(app, "spotlight-link-banner")
    // A system launch can land on the welcome screen; the link waits for the workspace.
    if app.buttons["open-local"].exists { app.buttons["open-local"].tap() }
    let ready = NSPredicate(format: "isEnabled == true")
    expectation(for: ready, evaluatedWith: open)
    waitForExpectations(timeout: 15)
    open.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, title)
    keep(app, "spotlight-row-opened")
  }

  /// Gallery discovery of every widget kind, Home Screen placement with a configured
  /// source, rendered titles and a row tap that opens the app on that record's link.
  func testGalleryAddsATitlesWidgetThatOpensItsRecord() throws {
    let app = try application()
    XCUIDevice.shared.press(.home)
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 2)
    let edit = springboard.buttons["Edit"]
    if edit.waitForExistence(timeout: 8) { edit.tap() }
    let add = springboard.buttons["Add Widget"]
    require(add, in: springboard, 10)
    add.tap()
    let search = springboard.searchFields.firstMatch
    require(search, in: springboard, 15)
    search.tap()
    search.typeText("Life UI")
    let entry = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Life UI'")
    ).element(boundBy: 1)
    require(entry, in: springboard, 15)
    keep(springboard, "widget-gallery-search")
    entry.tap()
    let page = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Life UI, '"))
    require(page.firstMatch, in: springboard, 15)
    // Walk every gallery page once; each kind and size has its own page.
    var seen: [String] = []
    for _ in 0..<12 {
      let current = page.allElementsBoundByIndex.filter(\.isHittable)
        .map { "\($0.label) \(($0.value as? String) ?? "")" }
      guard let label = current.first, !seen.contains(label) else { break }
      seen.append(label)
      springboard.swipeLeft()
    }
    let kinds = Set(seen.compactMap { $0.split(separator: ",").dropFirst().first?.trimmingCharacters(in: .whitespaces) })
    for kind in ["Table titles", "Today", "Record count", "Quick Add"] {
      XCTAssertTrue(kinds.contains { $0.hasPrefix(kind) }, "Gallery pages: \(seen)")
    }
    for _ in seen { springboard.swipeRight() }
    springboard.swipeLeft()  // Table titles, Medium
    let current = page.allElementsBoundByIndex.first(where: \.isHittable)
    XCTAssertEqual(current?.label, "Life UI, Table titles")
    XCTAssertTrue((current?.value as? String)?.contains("Medium") == true)
    keep(springboard, "widget-gallery-life-ui")
    let addWidget = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'"))
      .firstMatch
    require(addWidget, in: springboard, 10)
    addWidget.tap()
    let done = springboard.buttons["Done"]
    if done.waitForExistence(timeout: 10) { done.tap() }
    // Configure the placed widget to the enabled notes source.
    let widget = springboard.icons.matching(NSPredicate(format: "label CONTAINS 'Table titles' OR identifier CONTAINS 'Life UI'")).firstMatch
    require(widget, in: springboard, 15)
    widget.press(forDuration: 1.5)
    let editWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Edit Widget'")).firstMatch
    require(editWidget, in: springboard, 10)
    editWidget.tap()
    let choose = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Table or saved view' OR label == 'Choose'")).firstMatch
    require(choose, in: springboard, 15)
    choose.tap()
    let notes = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'notes'")).firstMatch
    require(notes, in: springboard, 15)
    notes.tap()
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
    let title = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'Quick Add fixture saved'")
    ).firstMatch
    require(title, in: springboard, 30)
    keep(springboard, "home-screen-titles-widget")
    title.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    if app.buttons["open-local"].waitForExistence(timeout: 5) { app.buttons["open-local"].tap() }
    XCTAssertTrue(app.buttons["open-pending-link"].waitForExistence(timeout: 15))
    keep(app, "widget-row-link-banner")
  }

  /// Lock Screen accessories expose a count and generic text, never record titles.
  func testLockScreenCountShowsNoRecordTitles() throws {
    _ = try application()
    let poster = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
    XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    sleep(2)
    XCUIDevice.shared.press(.home)
    sleep(1)
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 2.5)
    let customize = poster.buttons["Customize"]
    require(customize, in: poster, 15)
    customize.tap()
    let lockScreen = poster.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'Lock Screen'")).firstMatch
    // Older releases ask which surface to customize; iOS 27 opens the Lock Screen editor.
    if lockScreen.waitForExistence(timeout: 3) { lockScreen.tap() }
    let slots = poster.buttons.matching(identifier: "grouped-widgets-reticle-view")
    require(slots.firstMatch, in: poster, 15)
    // PosterBoard reports its reticles as not hittable; tap the slot's own frame.
    slots.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    // The widget picker can belong to PosterBoard or SpringBoard depending on the release.
    let lifeUI = poster.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'Life UI'")).firstMatch
    let pickerInSpringboard = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'Life UI'")).firstMatch
    for _ in 0..<6 where !lifeUI.exists && !pickerInSpringboard.exists { poster.swipeUp() }
    let picker = lifeUI.exists ? poster : springboard
    keep(picker, "lock-screen-widget-picker")
    require(lifeUI.exists ? lifeUI : pickerInSpringboard, in: picker, 10)
    (lifeUI.exists ? lifeUI : pickerInSpringboard).tap()
    keep(picker, "lock-screen-life-ui-widgets")
    // Add the rectangular count tile, then configure it to the enabled notes source.
    let tile = picker.buttons.matching(
      NSPredicate(format: "label == 'Life UI, Record count' AND value CONTAINS 'Rectangular'")
    ).firstMatch
    require(tile, in: picker, 15)
    tile.tap()
    let close = picker.buttons["close"]
    if close.waitForExistence(timeout: 5) { close.tap() }
    let placed = poster.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'Life UI' OR label CONTAINS 'Records'")).firstMatch
    require(placed, in: poster, 15)
    placed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    // The configuration list opens directly on current releases, or behind a Choose row.
    let notesQuery = NSPredicate(format: "label == 'notes'")
    let notesHere = poster.descendants(matching: .any).matching(notesQuery).firstMatch
    let notesThere = springboard.descendants(matching: .any).matching(notesQuery).firstMatch
    if !notesHere.waitForExistence(timeout: 5) && !notesThere.exists {
      let choose = poster.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS 'Table or saved view' OR label == 'Choose'")).firstMatch
      if choose.waitForExistence(timeout: 5) { choose.tap() }
    }
    let notes = notesHere.waitForExistence(timeout: 5) ? notesHere : notesThere
    require(notes, in: notesHere.exists ? poster : springboard, 10)
    keep(notesHere.exists ? poster : springboard, "lock-screen-count-source")
    notes.tap()
    sleep(2)
    if !poster.buttons["editing-done"].exists {
      poster.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    }
    let done = poster.buttons["editing-done"]
    require(done, in: poster, 10)
    done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    sleep(3)
    keep(springboard, "lock-screen-count-widget")
    let generic = springboard.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'records' OR label CONTAINS 'Records'")).firstMatch
    require(generic, in: springboard, 15)
    for label in ["Quick Add fixture saved", "A place to start"] {
      for process in [poster, springboard] {
        XCTAssertFalse(
          process.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label))
            .firstMatch.exists, "Lock Screen exposed a record title")
      }
    }
  }

  func testShareSheetPreparesADraftThatOpensUnsaved() throws {
    let app = try application()
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.open(URL(string: "https://example.com/life-ui-share-check")!)
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
    _ = safari.webViews.firstMatch.waitForExistence(timeout: 20)
    let share = safari.buttons.matching(
      NSPredicate(format: "identifier == 'ShareButton' OR label == 'Share'")
    ).firstMatch
    if !share.waitForExistence(timeout: 5) {
      // Newer Safari keeps Share inside the page menu.
      let menu = safari.buttons.matching(
        NSPredicate(format: "label IN {'More', 'Page Menu', 'Show Page Menu'}")
      ).firstMatch
      require(menu, in: safari, 10)
      menu.tap()
    }
    require(share, in: safari, 10)
    share.tap()
    let target = safari.descendants(matching: .any)["Life UI"].firstMatch
    require(target, in: safari, 15)
    target.tap()
    let prepare = safari.buttons["share-prepare"]
    XCTAssertTrue(prepare.waitForExistence(timeout: 20))
    keep(safari, "share-sheet-draft-form")
    prepare.tap()
    XCTAssertTrue(
      safari.staticTexts["Draft ready. Open Life UI to review and save it."].waitForExistence(timeout: 10))
    keep(safari, "share-sheet-draft-ready")
    safari.buttons["Done"].tap()
    app.launch()
    openWorkspace(app)
    let pending = app.buttons["open-quick-add"]
    XCTAssertTrue(pending.waitForExistence(timeout: 15))
    pending.tap()
    let field = app.textFields["field-title"]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    XCTAssertEqual(field.value as? String, "https://example.com/life-ui-share-check")
    keep(app, "share-draft-in-app")
  }
}
