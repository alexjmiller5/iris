import Foundation
import Testing

@testable import LifeKit

// Keep these in the existing serialized suite because ServiceFixture owns shared synthetic state.
extension HubServicesTests {
  @Test func registeredPushPollingReconcilesInboxAndReadStateWithoutLocalBanners() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    var registered = true
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center),
      isPushRegistered: { $0 == hub.endpoint && registered })
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.enableAlerts()
    ServiceFixture.state.appendEvent()
    await model.refresh()
    #expect(model.unreadCount == 206)
    #expect(model.feed?.notifications.last?.readAt == nil)
    #expect(center.requests.isEmpty)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 206)
    #expect(try alerts.state(endpoint: hub.endpoint).deliveredIDs.isEmpty)
    await model.markRead(id: "event-206")
    #expect(model.unreadCount == 205)
    #expect(model.feed?.notifications.last?.readAt != nil)
    #expect(center.requests.isEmpty)

    // Return to local mode from the latest inbox baseline, without replaying push-era history.
    registered = false
    ServiceFixture.state.appendEvent()
    await model.refresh()
    #expect(model.unreadCount == 206)
    #expect(center.requests.count == 1)
    #expect(center.requests.first?.content.title == "Synthetic event 207")
    #expect(try alerts.state(endpoint: hub.endpoint).deliveredIDs == ["event-207"])
    #expect(center.authorizationOptions.count == 1)
    try await workspace.close()
  }

  @Test func systemSchedulingRetryAndSharedReadRemainIndependentAcrossReconnect() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = SyntheticNotificationCenter()
    let alerts = NotificationAlerts(
      directory: directory, delivery: SystemNotificationDelivery(center: center))
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.enableAlerts()
    ServiceFixture.state.appendEvent()
    center.failScheduling = true
    await model.refresh()
    #expect(model.alertError != nil)
    #expect(model.unreadCount == 206)
    #expect(model.feed?.notifications.last?.readAt == nil)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 205)
    #expect(try alerts.state(endpoint: hub.endpoint).deliveredIDs.isEmpty)

    model.configure(workspace: nil, transport: nil)
    let reconnected = HubServicesModel(
      alerts: NotificationAlerts(
        directory: directory, delivery: SystemNotificationDelivery(center: center)))
    reconnected.configure(workspace: workspace, transport: hub)
    center.failScheduling = false
    await reconnected.refresh()
    #expect(reconnected.alertError == nil)
    #expect(center.requests.count == 1)
    #expect(reconnected.unreadCount == 206)
    #expect(reconnected.feed?.notifications.last?.readAt == nil)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 206)

    // Another device's read acknowledgement must reconcile without a second banner.
    _ = try await workspace.markNotificationsRead(
      using: hub, selector: ["ids": .array([.string("event-206")])])
    await reconnected.refresh()
    #expect(reconnected.unreadCount == 205)
    #expect(reconnected.feed?.notifications.last?.readAt != nil)
    #expect(center.requests.count == 1)
    #expect(center.authorizationOptions.count == 1)
    #expect(try alerts.state(endpoint: hub.endpoint).deliveredIDs == ["event-206"])
    try await workspace.close()
  }
}
