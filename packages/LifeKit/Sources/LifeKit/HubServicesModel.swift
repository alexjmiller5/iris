import Foundation
import Observation

@Observable @MainActor final class HubServicesModel {
  var usage: UsageSummary?
  var feed: NotificationFeed?
  var usageError: String?
  var notificationError: String?
  var alertError: String?
  var alertsEnabled = false
  var refreshing = false
  var usageRefreshing = false
  var changingAlerts = false
  private(set) var generation = 0
  private var workspace: NativeWorkspace?
  private var transport: HubTransport?
  private let alerts: NotificationAlerts

  init(alerts: NotificationAlerts? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("life-ui/alerts", isDirectory: true)
    self.alerts =
      alerts ?? NotificationAlerts(directory: directory, delivery: SystemNotificationDelivery())
  }
  var connected: Bool { transport != nil }
  var unreadCount: Int? { feed?.unreadCount }

  func configure(workspace: NativeWorkspace?, transport: HubTransport?) {
    generation += 1
    self.workspace = workspace
    self.transport = transport
    usage = nil
    feed = nil
    usageError = nil
    notificationError = nil
    alertError = nil
    alertsEnabled = false
    refreshing = false
    usageRefreshing = false
    changingAlerts = false
    if let transport {
      do { alertsEnabled = try alerts.state(endpoint: transport.endpoint).enabled } catch {
        alertError = error.localizedDescription
      }
    }
  }
  func refreshUsage() async {
    guard let workspace, let transport, !usageRefreshing else { return }
    let current = generation
    usageRefreshing = true
    defer { if current == generation { usageRefreshing = false } }
    do {
      let next = try await workspace.usage(using: transport)
      guard current == generation, !Task.isCancelled else { return }
      usage = next
      usageError = nil
    } catch {
      guard current == generation, !Task.isCancelled else { return }
      usageError = error.localizedDescription
    }
  }

  func refresh() async {
    guard let workspace, let transport, !refreshing else { return }
    let current = generation
    refreshing = true
    defer { if current == generation { refreshing = false } }
    await refreshNotifications(workspace: workspace, transport: transport, generation: current)
  }

  private func refreshNotifications(
    workspace: NativeWorkspace, transport: HubTransport, generation current: Int
  ) async {
    do {
      let next = try await workspace.notifications(using: transport)
      guard current == generation, !Task.isCancelled else { return }
      feed = next
      notificationError = nil
      do {
        let baseline = try alerts.state(endpoint: transport.endpoint).baseline
        let presentation = try await workspace.notificationPresentation(next, baseline: baseline)
        guard current == generation, !Task.isCancelled else { return }
        try await alerts.apply(
          presentation, endpoint: transport.endpoint,
          isCurrent: { [weak self] in self?.generation == current })
        guard current == generation, !Task.isCancelled else { return }
        alertError = nil
      } catch {
        guard current == generation, !Task.isCancelled else { return }
        alertError = error.localizedDescription
      }
    } catch {
      guard current == generation, !Task.isCancelled else { return }
      notificationError = error.localizedDescription
    }
  }

  func markRead(id: String? = nil) async {
    guard let workspace, let transport, let feed, !refreshing else { return }
    let current = generation
    refreshing = true
    defer { if current == generation { refreshing = false } }
    do {
      let selector: WorkspaceRecord =
        id.map { ["ids": .array([.string($0)])] }
        ?? ["through": .number(Double(feed.latestCursor))]
      _ = try await workspace.markNotificationsRead(using: transport, selector: selector)
      guard current == generation, !Task.isCancelled else { return }
      await refreshNotifications(workspace: workspace, transport: transport, generation: current)
    } catch {
      guard current == generation, !Task.isCancelled else { return }
      notificationError = error.localizedDescription
    }
  }

  func enableAlerts() async {
    guard let transport, !refreshing, !changingAlerts else { return }
    let current = generation
    changingAlerts = true
    defer { if current == generation { changingAlerts = false } }
    // Establish a complete baseline before requesting permission. History never floods the device.
    await refresh()
    guard current == generation, !Task.isCancelled, feed != nil,
      notificationError == nil, alertError == nil
    else { return }
    do {
      let enabled = try await alerts.enable(endpoint: transport.endpoint)
      guard current == generation else { return }
      alertsEnabled = enabled
      alertError =
        enabled ? nil : "Alerts were not enabled. You can allow notifications in system settings."
    } catch { if current == generation { alertError = error.localizedDescription } }
  }
  func disableAlerts() {
    guard let transport, !refreshing, !changingAlerts else { return }
    do {
      try alerts.disable(endpoint: transport.endpoint)
      alertsEnabled = false
      alertError = nil
    } catch { alertError = error.localizedDescription }
  }

  func poll(interval: Duration = .seconds(60)) async {
    let current = generation
    while current == generation, connected, !Task.isCancelled {
      await refresh()
      do { try await Task.sleep(for: interval) } catch { return }
    }
  }
}
