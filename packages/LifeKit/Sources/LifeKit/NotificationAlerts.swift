import CryptoKit
import Foundation
import UserNotifications

@MainActor protocol NotificationDelivery {
  func requestAuthorization() async throws -> Bool
  // Recheck after any suspension. False suppresses presentation; throwing rejects a stale refresh.
  func present(
    _ notification: HubNotification, identifier: String, shouldPresent: () throws -> Bool
  ) async throws -> Bool
}

struct NotificationAlertState: Codable {
  var enabled = false
  var baseline: Int?
  // Keep the existing JSON array format without String Set's Unicode folding.
  var deliveredIDs: [String] = []
}

@MainActor final class NotificationAlerts {
  private let directory: URL
  private let delivery: any NotificationDelivery
  private let isPushRegistered: (String) -> Bool
  init(
    directory: URL, delivery: any NotificationDelivery,
    isPushRegistered: @escaping (String) -> Bool = { _ in false }
  ) {
    self.directory = directory
    self.delivery = delivery
    self.isPushRegistered = isPushRegistered
  }
  func state(endpoint: String) throws -> NotificationAlertState {
    let url = file(endpoint)
    guard FileManager.default.fileExists(atPath: url.path) else { return NotificationAlertState() }
    return try JSONDecoder().decode(NotificationAlertState.self, from: Data(contentsOf: url))
  }
  func enable(endpoint: String) async throws -> Bool {
    let granted = try await delivery.requestAuthorization()
    var next = try state(endpoint: endpoint)
    next.enabled = granted
    try save(next, endpoint: endpoint)
    return granted
  }
  func disable(endpoint: String) throws {
    var next = try state(endpoint: endpoint)
    next.enabled = false
    try save(next, endpoint: endpoint)
  }
  func apply(
    _ presentation: NotificationPresentation, endpoint: String, isCurrent: () -> Bool = { true }
  ) async throws {
    var next = try state(endpoint: endpoint)
    var delivered = Set(next.deliveredIDs.map { Data($0.utf8) })
    if next.enabled, !isPushRegistered(endpoint) {
      for notification in presentation.notifications
      where !delivered.contains(Data(notification.id.utf8)) {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let scheduled = try await delivery.present(
          notification, identifier: "life-ui." + digest(endpoint) + "." + digest(notification.id),
          shouldPresent: {
            guard isCurrent() else { throw CancellationError() }
            return !isPushRegistered(endpoint)
          })
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard scheduled else { break }
        next.deliveredIDs.append(notification.id)
        delivered.insert(Data(notification.id.utf8))
        // Preserve successful IDs across retries if a later delivery fails.
        try save(next, endpoint: endpoint)
      }
    }
    try Task.checkCancellation()
    guard isCurrent() else { throw CancellationError() }
    next.baseline = presentation.baseline
    try save(next, endpoint: endpoint)
  }
  private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func file(_ endpoint: String) -> URL {
    directory.appendingPathComponent(digest(endpoint) + ".json")
  }
  private func save(_ state: NotificationAlertState, endpoint: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = file(endpoint)
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

@MainActor protocol NotificationCenterClient {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func authorizationStatus() async -> UNAuthorizationStatus
  func add(_ request: UNNotificationRequest) async throws
}

@MainActor final class SystemNotificationDelivery: NotificationDelivery {
  private let center: any NotificationCenterClient

  init(center: any NotificationCenterClient = NativeNotificationCenter()) {
    self.center = center
  }

  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .sound])
  }
  func present(
    _ notification: HubNotification, identifier: String, shouldPresent: () throws -> Bool
  ) async throws -> Bool {
    let status = await center.authorizationStatus()
    // The hub may disconnect or switch while the system settings request is suspended.
    try Task.checkCancellation()
    guard try shouldPresent() else { return false }
    guard
      status == .authorized || status == .provisional
    else {
      throw WorkspaceError(
        message:
          "Alerts are disabled in system settings. Enable notifications there or turn off alerts for this hub.",
        violations: [])
    }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    try await center.add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    return true
  }
}

// The center is deliberately lazy: SwiftPM tests run without an application bundle.
@MainActor
private final class NativeNotificationCenter: NSObject, NotificationCenterClient,
  UNUserNotificationCenterDelegate
{
  private var center: UNUserNotificationCenter {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    return center
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    try await center.requestAuthorization(options: options)
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await center.add(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }
}
