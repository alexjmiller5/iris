import XCTest

@MainActor
final class ServiceIdentityUITests: XCTestCase {
  func testByteDistinctNotificationsDisplayAndMarkOnlyTheirOwnID() async throws {
    let endpoint = try fixtureEndpoint()
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    try openServices(app, destination: "hub-notifications")
    XCTAssertTrue(app.staticTexts["2 unread"].waitForExistence(timeout: 10))
    let first = app.staticTexts["Opaque first notice"]
    for _ in 0..<5 where !(first.exists && first.isHittable) { app.swipeUp() }
    capture(app, name: "native-distinct-notifications")
    XCTAssertTrue(first.exists, "Both opaque event IDs must render independently")
    XCTAssertTrue(app.staticTexts["Opaque second notice"].exists)
    // Select by the exact UTF-8 accessibility identifier, not NSString equivalence.
    let mark = app.buttons.allElementsBoundByIndex.first {
      Data($0.identifier.utf8) == Data("mark-read-\u{00e9}".utf8)
    }
    let button = try XCTUnwrap(mark)
    XCTAssertTrue(button.isHittable)
    button.tap()
    waitForReadButtonRemoval(app)
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: endpoint)).appendingPathComponent("v1/notifications"))
    request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try XCTUnwrap(body["notifications"] as? [[String: Any]])
    let read = try XCTUnwrap(
      rows.first { Data(($0["id"] as? String ?? "").utf8) == Data([0xc3, 0xa9]) })
    let unread = try XCTUnwrap(
      rows.first { Data(($0["id"] as? String ?? "").utf8) == Data([0x65, 0xcc, 0x81]) })
    XCTAssertTrue(read["read_at"] is String)
    XCTAssertTrue(unread["read_at"] is NSNull)
    // No manual refresh: reopening the inbox reloads it.
    app.navigationBars["Notifications"].buttons.element(boundBy: 0).tap()
    app.buttons["hub-notifications"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Opaque second notice"].exists)
  }

  func testByteDistinctUsageDevicesKeepTheirOwnLabelsAndTotals() throws {
    _ = try fixtureEndpoint()
    let app = XCUIApplication()
    app.launch()
    defer { app.terminate() }
    try openServices(app, destination: "hub-usage")
    let first = app.staticTexts["Opaque first device"]
    for _ in 0..<10 where !(first.exists && first.isHittable) { app.swipeUp() }
    capture(app, name: "native-distinct-usage-devices")
    XCTAssertTrue(first.exists, "Opaque usage IDs must retain each device's label")
    XCTAssertTrue(app.staticTexts["Opaque second device"].exists)
    let firstRow = app.cells.containing(.staticText, identifier: "Opaque first device").firstMatch
    let secondRow = app.cells.containing(.staticText, identifier: "Opaque second device").firstMatch
    XCTAssertTrue(firstRow.staticTexts["Rows read, 101"].exists)
    XCTAssertTrue(secondRow.staticTexts["Rows read, 202"].exists)
  }

  private func fixtureEndpoint() throws -> String {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    guard let endpoint = environment["IRIS_TEST_SERVICE_ID_HUB"],
      environment["IRIS_TEST_SERVICE_ID_SIMULATOR"] != nil
    else { throw XCTSkip("Requires the synthetic service identity fixture and private simulator") }
    XCTAssertEqual(environment["IRIS_TEST_SERVICE_ID_SIMULATOR"], environment["SIMULATOR_UDID"])
    let url = try XCTUnwrap(URL(string: endpoint))
    XCTAssertEqual(url.host, "127.0.0.1")
    XCTAssertEqual(url.scheme, "http")
    return endpoint
  }

  private func openServices(_ app: XCUIApplication, destination: String) throws {
    let bar = app.navigationBars["widgets"]
    XCTAssertTrue(bar.waitForExistence(timeout: 20))
    app.buttons["workspace-menu"].tap()
    let settings = app.buttons["Hub connection"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()
    let link = app.buttons[destination]
    XCTAssertTrue(link.waitForExistence(timeout: 5))
    link.tap()
  }

  private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  private func waitForReadButtonRemoval(_ app: XCUIApplication) {
    let removed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          !app.buttons.allElementsBoundByIndex.contains {
            Data($0.identifier.utf8) == Data("mark-read-\u{00e9}".utf8)
          }
        }
      }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
  }
}
