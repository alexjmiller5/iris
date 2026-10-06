import Foundation
import Testing
import UserNotifications

@testable import LifeKit

@MainActor struct NotificationSchedulingTests {
  @Test(arguments: [false, true])
  func registeredPushSuppressesPollingBannerAndStillAdvancesInboxBaseline(
    registersDuringPermissionLookup: Bool
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    let endpoint = "https://notifications.invalid"
    var pushRegistered = !registersDuringPermissionLookup
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center),
      isPushRegistered: { $0 == endpoint && pushRegistered })
    #expect(try await alerts.enable(endpoint: endpoint))
    center.onStatus = { pushRegistered = true }
    try await alerts.apply(.init(notifications: [event], baseline: 8), endpoint: endpoint)
    #expect(center.requests.isEmpty)
    #expect(try alerts.state(endpoint: endpoint).baseline == 8)
    #expect(try alerts.state(endpoint: endpoint).deliveredIDs.isEmpty)
    #expect(center.authorizationOptions.count == 1)

    // Registration on one deployment cannot suppress another deployment's local alerts.
    let other = "https://another.invalid"
    #expect(try await alerts.enable(endpoint: other))
    try await alerts.apply(.init(notifications: [event], baseline: 8), endpoint: other)
    #expect(center.requests.count == 1)

    // A revoked registration returns to local presentation without changing original event IDs.
    pushRegistered = false
    center.onStatus = nil
    var next = event
    next.id = "next-event"
    next.seq = 9
    try await alerts.apply(.init(notifications: [next], baseline: 9), endpoint: endpoint)
    #expect(center.requests.count == 2)
    #expect(try alerts.state(endpoint: endpoint).deliveredIDs == ["next-event"])
  }

  @Test(arguments: [UNAuthorizationStatus.notDetermined, .denied])
  func unavailablePermissionRetainsEventForRetry(status: UNAuthorizationStatus) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center))
    let endpoint = "https://notifications.invalid"
    #expect(try await alerts.enable(endpoint: endpoint))
    #expect(center.authorizationOptions == [[.alert, .sound]])
    center.status = status
    await #expect(throws: WorkspaceError.self) {
      try await alerts.apply(.init(notifications: [event], baseline: 8), endpoint: endpoint)
    }
    #expect(center.requests.isEmpty)
    #expect(try alerts.state(endpoint: endpoint).baseline == nil)
    #expect(try alerts.state(endpoint: endpoint).deliveredIDs.isEmpty)
    // Polling must never trigger another permission prompt.
    #expect(center.authorizationOptions.count == 1)
    center.status = .authorized
    try await alerts.apply(.init(notifications: [event], baseline: 8), endpoint: endpoint)
    #expect(center.requests.count == 1)
  }

  @Test(arguments: [UNAuthorizationStatus.authorized, .provisional])
  func schedulesOriginalContentWithStableIdentifier(status: UNAuthorizationStatus) async throws {
    let center = SyntheticNotificationCenter()
    center.status = status
    #expect(
      try await SystemNotificationDelivery(center: center).present(
        event, identifier: "synthetic-delivery", shouldPresent: { true }))
    let request = try #require(center.requests.first)
    #expect(request.identifier == "synthetic-delivery")
    #expect(request.content.title == event.title)
    #expect(request.content.body == event.body)
    #expect(request.content.sound != nil)
    #expect(request.trigger == nil)
    #expect(center.authorizationOptions.isEmpty)
  }

  @Test(arguments: [false, true])
  func invalidationDuringPermissionLookupDoesNotScheduleOrConsumeEvent(cancel: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center))
    let endpoint = "https://notifications.invalid"
    try await alerts.apply(.init(notifications: [], baseline: 7), endpoint: endpoint)
    #expect(try await alerts.enable(endpoint: endpoint))
    var current = true
    center.onStatus = {
      if cancel {
        withUnsafeCurrentTask { $0?.cancel() }
      } else {
        current = false
      }
    }
    let presentation = NotificationPresentation(notifications: [event], baseline: 8)
    let task = Task {
      try await alerts.apply(presentation, endpoint: endpoint, isCurrent: { current })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(center.requests.isEmpty)
    #expect(try alerts.state(endpoint: endpoint).deliveredIDs.isEmpty)
    #expect(try alerts.state(endpoint: endpoint).baseline == 7)

    // Reconnecting retries the event that never reached the OS.
    center.onStatus = nil
    let reconnected = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center))
    try await reconnected.apply(presentation, endpoint: endpoint)
    #expect(center.requests.count == 1)
    #expect(try reconnected.state(endpoint: endpoint).baseline == 8)
  }

  @Test(arguments: [false, true])
  func lateSchedulingReceiptCannotConsumeEventFromInvalidatedRefresh(cancel: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center))
    let endpoint = "https://notifications.invalid"
    try await alerts.apply(.init(notifications: [], baseline: 7), endpoint: endpoint)
    #expect(try await alerts.enable(endpoint: endpoint))
    var current = true
    center.onAdd = {
      if cancel {
        withUnsafeCurrentTask { $0?.cancel() }
      } else {
        current = false
      }
    }
    let task = Task {
      try await alerts.apply(
        .init(notifications: [event], baseline: 8), endpoint: endpoint, isCurrent: { current })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    // The request already reached the OS; its late receipt cannot commit the obsolete refresh.
    #expect(center.requests.count == 1)
    #expect(try alerts.state(endpoint: endpoint).deliveredIDs.isEmpty)
    #expect(try alerts.state(endpoint: endpoint).baseline == 7)
    #expect(try alerts.state(endpoint: "https://another.invalid").baseline == nil)
  }

  private var event: HubNotification {
    .init(
      seq: 8, id: "synthetic-event", createdAt: "2026-01-01T00:00:00.000Z",
      producer: "fixture", type: "fixture.event", severity: "info",
      title: "Synthetic title", body: "Synthetic body", data: .null, readAt: nil)
  }
}

@MainActor final class SyntheticNotificationCenter: NotificationCenterClient {
  var status: UNAuthorizationStatus = .authorized
  var onStatus: (() -> Void)?
  var onAdd: (() -> Void)?
  var requests: [UNNotificationRequest] = []
  var authorizationOptions: [UNAuthorizationOptions] = []
  var failScheduling = false

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    authorizationOptions.append(options)
    return true
  }
  func authorizationStatus() async -> UNAuthorizationStatus {
    onStatus?()
    return status
  }
  func add(_ request: UNNotificationRequest) async throws {
    if failScheduling { throw URLError(.cannotConnectToHost) }
    requests.append(request)
    onAdd?()
  }
}
