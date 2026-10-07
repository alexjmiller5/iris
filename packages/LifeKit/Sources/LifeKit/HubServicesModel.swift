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
  private let pushDevice: any PushNotificationDevice
  private let pushSession: (HubTransport) async throws -> CoreSessionInfo?
  private(set) var pushApprovalURL: URL?
  private var push: PushRegistration?
  private var capability: CorePushRegistrationCapability?
  private var pushObserver: UUID?
  private var askedForToken = false
  var pushReady: Bool { push?.ready == true }
  var pushError: String? { pushDevice.error ?? push?.error }

  init(
    alerts: NotificationAlerts? = nil,
    pushDevice: any PushNotificationDevice = NativePushNotifications.shared,
    pushSession: @escaping (HubTransport) async throws -> CoreSessionInfo? = {
      hub in
      let reply = try await hub.sessionReply(maxResponseBytes: 65536)
      if reply.status == 401 || reply.status == 403 { return nil }
      guard reply.status == 200 else { throw URLError(.badServerResponse) }
      let core = try EnrollmentCore()
      let session = try await core.request(
        CoreRequests.ValidateDeviceSession(CoreSessionDataArgs(data: reply.data)))
      return session
    }
  ) {
    self.pushDevice = pushDevice
    self.pushSession = pushSession
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
    push?.invalidate()
    push = nil
    capability = nil
    pushApprovalURL = nil
    askedForToken = false
    if let pushObserver { pushDevice.removeObserver(pushObserver) }
    pushObserver = nil
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
    await refreshPush(transport: transport, generation: current)
    guard current == generation, !Task.isCancelled else { return }
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
          isCurrent: { [weak self] in self?.generation == current },
          pushRegistered: { [weak self] in self?.pushReady == true })
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
      if enabled { await refreshPush(transport: transport, generation: current) }
      guard current == generation else { return }
      alertError =
        enabled ? nil : "Alerts were not enabled. You can allow notifications in system settings."
    } catch { if current == generation { alertError = error.localizedDescription } }
  }
  func disableAlerts() {
    guard let transport, !refreshing, !changingAlerts else { return }
    do {
      try alerts.disable(endpoint: transport.endpoint)
      alertsEnabled = false
      push?.beginRevocation()
      if let push { Task { await push.retry() } }
      alertError = nil
    } catch { alertError = error.localizedDescription }
  }

  private func refreshPush(transport: HubTransport, generation current: Int) async {
    do {
      let session = try await pushSession(transport)
      let next = session?.pushRegistration
      guard current == generation, !Task.isCancelled else { return }
      pushApprovalURL = nil
      let profiles = session?.pushProfiles?.filter { $0.platform == pushDevice.platform } ?? []
      if next == nil, profiles.count == 1 {
        let url = try await transport.pushApprovalURL(profile: profiles[0].id)
        guard current == generation, !Task.isCancelled else { return }
        pushApprovalURL = url
      }
      guard let next,
        let profile = next.profiles.first(where: { $0.platform == pushDevice.platform })
      else {
        push?.invalidate()
        push = nil
        capability = nil
        return
      }
      let sameBinding =
        capability.map { previous in
          previous.protocol.utf8.elementsEqual(next.protocol.utf8)
            && previous.deploymentIdentity.utf8.elementsEqual(next.deploymentIdentity.utf8)
            && previous.sessionBinding.utf8.elementsEqual(next.sessionBinding.utf8)
            && previous.profiles.count == next.profiles.count
            && zip(previous.profiles, next.profiles).allSatisfy {
              $0.id.utf8.elementsEqual($1.id.utf8) && $0.platform == $1.platform
            }
        } ?? false
      if !sameBinding {
        push?.invalidate()
        capability = next
        push = PushRegistration(
          capability: next, appProfile: profile.id,
          isAllowed: { [weak self] in
            guard let self, self.generation == current else { return false }
            return (try? self.alerts.state(endpoint: transport.endpoint).enabled) == true
          },
          isCurrentToken: { [weak self] in self?.pushDevice.token == $0 },
          exchange: { try await transport.pushRegistration($0) })
      }
      if pushObserver == nil {
        pushObserver = pushDevice.observe { [weak self] token in
          guard let self, self.generation == current else { return }
          Task { [weak self] in
            guard let self, self.generation == current else { return }
            guard (try? self.alerts.state(endpoint: transport.endpoint).enabled) == true else {
              return
            }
            await self.push?.enable(token: token)
          }
        }
      }
      guard (try? alerts.state(endpoint: transport.endpoint).enabled) == true else {
        await push?.ensureRevoked()
        return
      }
      if !askedForToken || pushDevice.error != nil {
        askedForToken = true
        pushDevice.register()
      }
      if let token = pushDevice.token { await push?.enable(token: token) }
    } catch {
      // A temporary network error does not turn an already confirmed server
      // registration into permission for a competing local banner.
    }
  }

  func revokePushBeforeForgetting() async throws {
    guard let transport else { return }
    let current = generation
    var retiring = push
    if retiring == nil {
      // Local disable is persisted before the server acknowledges revocation.
      // After relaunch, resolve the server binding even when that preference is off.
      guard let session = try await pushSession(transport) else {
        throw WorkspaceError(
          message: "Push could not be checked. Retry before forgetting this connection.",
          violations: [])
      }
      let next = session.pushRegistration
      guard current == generation, !Task.isCancelled else { throw CancellationError() }
      if let next, let profile = next.profiles.first(where: { $0.platform == pushDevice.platform })
      {
        retiring = PushRegistration(
          capability: next, appProfile: profile.id,
          exchange: { try await transport.pushRegistration($0) })
      }
    }
    guard let retiring else { return }
    await retiring.revoke()
    guard current == generation, !Task.isCancelled else { throw CancellationError() }
    guard retiring.revoked else {
      throw WorkspaceError(
        message: "Push could not be turned off. Retry before forgetting this connection.",
        violations: [])
    }
  }

  func poll(interval: Duration = .seconds(60)) async {
    let current = generation
    while current == generation, connected, !Task.isCancelled {
      await refresh()
      do { try await Task.sleep(for: interval) } catch { return }
    }
  }
}
