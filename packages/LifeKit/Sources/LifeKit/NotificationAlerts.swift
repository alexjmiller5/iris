import CryptoKit
import Foundation
import UserNotifications

@MainActor protocol NotificationDelivery {
  func requestAuthorization() async throws -> Bool
  func present(_ notification: HubNotification, identifier: String) async throws
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
  init(directory: URL, delivery: any NotificationDelivery) {
    self.directory = directory
    self.delivery = delivery
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
    if next.enabled {
      for notification in presentation.notifications
      where !delivered.contains(Data(notification.id.utf8)) {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        try await delivery.present(
          notification, identifier: "life-ui." + digest(endpoint) + "." + digest(notification.id))
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

// The center is deliberately lazy: SwiftPM tests run without an application bundle.
@MainActor
final class SystemNotificationDelivery: NSObject, NotificationDelivery,
  UNUserNotificationCenterDelegate
{
  private var center: UNUserNotificationCenter {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    return center
  }
  func requestAuthorization() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .sound])
  }
  func present(_ notification: HubNotification, identifier: String) async throws {
    let center = center
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
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
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }
}
