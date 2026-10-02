import Foundation
import Testing

@testable import LifeKit

@MainActor struct NotificationAlertsTests {
  @Test func firstContactAndDisabledAlertsPersistBaselineWithoutRequestingPermission() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    try await alerts.apply(.init(notifications: [], baseline: 7), endpoint: "https://one.invalid")
    #expect(try alerts.state(endpoint: "https://one.invalid").baseline == 7)
    #expect(try alerts.state(endpoint: "https://two.invalid").baseline == nil)
    #expect(delivery.authorizationRequests == 0)
    #expect(delivery.delivered.isEmpty)
    let reloaded = NotificationAlerts(directory: directory, delivery: delivery)
    #expect(try reloaded.state(endpoint: "https://one.invalid").baseline == 7)
  }

  @Test func explicitAuthorizationDenialDoesNotEnableAlerts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    delivery.granted = false
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    #expect(try await alerts.enable(endpoint: "https://one.invalid") == false)
    #expect(delivery.authorizationRequests == 1)
    #expect(try !alerts.state(endpoint: "https://one.invalid").enabled)
  }

  @Test func retryDoesNotDuplicateDeliveredIDsAndAdvancesOnlyAfterSuccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    let endpoint = "https://one.invalid"
    try await alerts.apply(.init(notifications: [], baseline: 7), endpoint: endpoint)
    #expect(try await alerts.enable(endpoint: endpoint))
    delivery.failID = "event-9"
    let events = [event(8), event(9)]
    await #expect(throws: Error.self) {
      try await alerts.apply(.init(notifications: events, baseline: 9), endpoint: endpoint)
    }
    #expect(try alerts.state(endpoint: endpoint).baseline == 7)
    #expect(delivery.delivered.count == 1)
    delivery.failID = nil
    let reloaded = NotificationAlerts(directory: directory, delivery: delivery)
    try await reloaded.apply(.init(notifications: events, baseline: 9), endpoint: endpoint)
    #expect(delivery.delivered.count == 2)
    #expect(Set(delivery.delivered).count == 2)
    #expect(try reloaded.state(endpoint: endpoint).baseline == 9)
    try await reloaded.apply(.init(notifications: [event(8)], baseline: 10), endpoint: endpoint)
    #expect(delivery.delivered.count == 2)
    #expect(try await alerts.enable(endpoint: "https://two.invalid"))
    try await alerts.apply(
      .init(notifications: [event(8)], baseline: 8), endpoint: "https://two.invalid")
    #expect(Set(delivery.delivered).count == 3)
    try alerts.disable(endpoint: endpoint)
    try await alerts.apply(.init(notifications: [event(11)], baseline: 11), endpoint: endpoint)
    #expect(delivery.delivered.count == 3)
    #expect(try alerts.state(endpoint: endpoint).baseline == 11)
  }

  private func event(_ seq: Int) -> HubNotification {
    .init(
      seq: seq, id: "event-\(seq)", createdAt: "2026-10-02T15:04:05.123Z", producer: "fixture",
      type: "fixture.event", severity: "info", title: "Synthetic event \(seq)",
      body: "Fixture body", data: .null, readAt: nil)
  }
}

@MainActor final class FixtureNotificationDelivery: NotificationDelivery {
  var granted = true
  var authorizationRequests = 0
  var delivered: [String] = []
  var failID: String?
  var onPresent: (() -> Void)?
  func requestAuthorization() async throws -> Bool {
    authorizationRequests += 1
    return granted
  }
  func present(_ notification: HubNotification, identifier: String) async throws {
    if notification.id == failID { throw URLError(.cannotConnectToHost) }
    delivered.append(identifier)
    onPresent?()
  }
}
