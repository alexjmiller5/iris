import CryptoKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// One local notification at a row's specific due time.
struct DueAlertRequest: Equatable, Sendable {
  let identifier: String
  let title: String
  let body: String
  let link: URL
  /// When it fires in the zone the value was resolved in.
  let at: Date
  /// A floating local time fires at its wall clock wherever the device is; a pinned
  /// zone or a UTC instant fires at the exact instant.
  let floating: Bool
}

/// The system's pending local notifications, behind a seam for tests.
@MainActor protocol DueAlertCenter: AnyObject {
  /// Only the explicit Enable alerts action ever requests permission.
  func authorized() async -> Bool
  func pendingIdentifiers() async -> [String]
  func add(_ request: DueAlertRequest) async throws
  func remove(_ identifiers: [String])
}

enum DueAlerts {
  /// The platform's pending local notification limit (iOS keeps 64).
  static let limit = 64

  static func prefix(workspaceID: String) -> String {
    "iris.due." + hash(workspaceID) + "."
  }

  static func identifier(workspaceID: String, table: String, rowID: String, value: String)
    -> String
  {
    prefix(workspaceID: workspaceID) + hash([table, rowID, value].joined(separator: "\u{0}"))
  }

  /// Nearest first and capped; one alert per row and due time even when several
  /// chosen views select it.
  static func plan(_ requests: [DueAlertRequest], pending: [String], prefix: String) -> (
    add: [DueAlertRequest], remove: [String]
  ) {
    var seen = Set<String>()
    let desired = requests.sorted { $0.at < $1.at }.filter { seen.insert($0.identifier).inserted }
      .prefix(limit)
    let wanted = Set(desired.map(\.identifier))
    let ours = pending.filter { $0.hasPrefix(prefix) }
    return (
      desired.filter { !ours.contains($0.identifier) },
      ours.filter { !wanted.contains($0) }
    )
  }

  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
}

/// Notification taps reach the window as ordinary pending links (iris://open/v1).
@Observable @MainActor final class DueAlertLinks {
  static let shared = DueAlertLinks()
  private(set) var link: (url: URL, revision: Int)?
  func open(_ url: URL) { link = (url, (link?.revision ?? 0) + 1) }

  /// The notification delegate's half: only a link this app scheduled is accepted.
  nonisolated static func received(_ userInfo: [AnyHashable: Any]) {
    guard let text = userInfo["irisLink"] as? String, let url = URL(string: text),
      url.scheme == "iris"
    else { return }
    Task { @MainActor in shared.open(url) }
  }
}

@MainActor final class SystemDueAlertCenter: DueAlertCenter {
  /// Nil outside an app bundle (SwiftPM tests), where the system center would trap.
  private var center: UNUserNotificationCenter? {
    Bundle.main.bundleIdentifier == nil ? nil : .current()
  }

  func authorized() async -> Bool {
    guard let center else { return false }
    return [.authorized, .provisional].contains(
      await center.notificationSettings().authorizationStatus)
  }

  func pendingIdentifiers() async -> [String] {
    await center?.pendingNotificationRequests().map(\.identifier) ?? []
  }

  func add(_ request: DueAlertRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = .default
    content.userInfo = ["irisLink": request.link.absoluteString]
    var calendar = Calendar(identifier: .gregorian)
    if request.floating { calendar.timeZone = .current } else { calendar.timeZone = .gmt }
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: request.at)
    // Without a zone the trigger follows the device's current wall clock.
    components.timeZone = request.floating ? nil : .gmt
    try await center?.add(
      UNNotificationRequest(
        identifier: request.identifier, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
  }

  func remove(_ identifiers: [String]) {
    guard !identifiers.isEmpty else { return }
    center?.removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}

/// Settings > Due-time alerts: the saved views whose rows notify this device.
struct DueAlertsView: View {
  let model: WorkspaceModel
  @State private var views: [CoreSavedViewRecord] = []
  @State private var loading = true
  @State private var authorized: Bool?
  @State private var failure: String?

  var body: some View {
    Form {
      Section {
        Text(
          "Iris notifies this device when a record in a chosen saved view reaches its specific due time. Date-only values never notify."
        )
        if authorized == false {
          Text(
            "Turn on Enable alerts in the hub's Notifications first. Iris asks for permission only there."
          )
          .foregroundStyle(.secondary).accessibilityIdentifier("due-alerts-permission")
        }
      }
      if let settings = model.integrations {
        Section("Saved views") {
          if loading {
            SkeletonRows(count: 3, label: "Loading saved views")
          } else if views.isEmpty {
            Text("No saved view has a date filter or calendar date.").foregroundStyle(.secondary)
          }
          ForEach(views, id: \.id) { view in
            let selection = NativeWidgetSelection(table: view.tbl, viewID: view.id)
            Toggle(
              isOn: Binding(
                get: { settings.alertViews.contains { $0.id == selection.id } },
                set: { on in
                  let rest = settings.alertViews.filter { $0.id != selection.id }
                  Task { await settings.setAlertViews(on ? rest + [selection] : rest) }
                })
            ) {
              VStack(alignment: .leading) {
                Text(view.name)
                Text(view.tbl).font(.caption).foregroundStyle(.secondary)
              }
            }
            .accessibilityIdentifier("due-alert-" + view.name)
          }
        }
        if let message = settings.alertError ?? failure {
          Section { Text(message).foregroundStyle(.red) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Due-time alerts")
    .task {
      authorized = await SystemDueAlertCenter().authorized()
      // Creates this saved workspace's private identity on first use, as widgets do.
      do { try model.prepareIntegrations() } catch { failure = error.localizedDescription }
      guard let workspace = model.client else { return }
      defer { loading = false }
      do {
        var found: [CoreSavedViewRecord] = []
        for table in model.tables.compactMap({ $0["id"]?.text }) {
          found += try await workspace.listViews(table: table).views.filter {
            $0.deletedAt == nil && $0.unavailable == nil
              && $0.definition.flatMap(DueTimes.dueColumn) != nil
          }
        }
        guard model.client === workspace else { return }
        views = found
      } catch {
        if !Task.isCancelled { failure = error.localizedDescription }
      }
    }
  }
}
