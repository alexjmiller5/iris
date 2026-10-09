import SwiftUI

struct HubUsageView: View {
  let services: HubServicesModel
  private let metrics = [
    ("d1_rows_read", "Rows read"), ("d1_rows_written", "Rows written"),
    ("requests", "Requests"), ("d1_storage_bytes", "Storage"),
  ]

  var body: some View {
    Form {
      if let usage = services.usage {
        Section {
          LabeledContent("Period starts", value: serviceDate(usage.period.start))
          LabeledContent("Resets", value: serviceDate(usage.period.end))
          Text(
            usage.measuredAt.map { "Measured: \(serviceDate($0))" } ?? "No measurement available"
          )
          .font(.caption).foregroundStyle(.secondary)
          if let cap = usage.capped {
            Label(
              "Sync paused: \(metricName(cap.metric)) cap reached.", systemImage: "pause.circle"
            )
            .foregroundStyle(.orange)
            Text("Resumes \(serviceDate(cap.resetsAt)).")
          }
        } header: {
          Text("This deployment")
        } footer: {
          Text(
            "Current period totals for this hub. Storage is a current measurement, not a period total."
          )
        }
        ForEach(metrics, id: \.0) { key, title in
          Section(title) {
            if let metric = usage.metrics[key] {
              LabeledContent(
                "Used", value: metric.used.map { amount($0, unit: metric.unit) } ?? "Unmeasured")
              LabeledContent(
                "Free allowance",
                value: metric.allowance.map { amount($0, unit: metric.unit) } ?? "Unmeasured")
              LabeledContent(
                "Hard cap",
                value: metric.cap.map { amount($0, unit: metric.unit) } ?? "None configured")
              if let used = metric.used, let allowance = metric.allowance, allowance > 0 {
                ProgressView(value: min(used / allowance, 1))
                  .accessibilityLabel("Free allowance used")
                  .accessibilityValue(
                    (used / allowance).formatted(.percent.precision(.fractionLength(1))))
                Text(
                  "\((used / allowance).formatted(.percent.precision(.fractionLength(1)))) of free allowance"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Text(
                metric.measuredAt.map { "Measured: \(serviceDate($0))" }
                  ?? "No measurement available"
              )
              .font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Unmeasured").foregroundStyle(.secondary)
            }
          }.accessibilityIdentifier("usage-metric-" + key)
        }
        Section {
          ForEach(usage.byPrincipal, id: \.byteExactID) { principal in
            VStack(alignment: .leading, spacing: 6) {
              Text(principal.label ?? principal.id).font(.headline)
              Text(principal.kind).font(.caption).foregroundStyle(.secondary)
              LabeledContent("Rows read", value: principal.rowsRead.formatted(.number))
              LabeledContent("Rows written", value: principal.rowsWritten.formatted(.number))
              LabeledContent("Requests", value: principal.requests.formatted(.number))
            }.padding(.vertical, 4)
          }
        } header: {
          Text("Devices and services")
        } footer: {
          Text(
            "Current period totals. Storage is measured for the entire deployment."
          )
        }
      } else if services.usageRefreshing {
        ProgressView("Loading usage…")
      }
      if let error = services.usageError {
        Text(error).foregroundStyle(.red)
        Text("Displayed measurements, if any, are from the last successful refresh.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Usage")
    .task { await services.refreshUsage() }
  }

  private func metricName(_ key: String) -> String { metrics.first { $0.0 == key }?.1 ?? key }
  private func amount(_ value: Double, unit: String) -> String {
    unit == "bytes" ? value.formatted(.number) + " bytes" : value.formatted(.number)
  }
}

struct HubNotificationsView: View {
  @Environment(\.openURL) private var openURL
  let services: HubServicesModel
  var body: some View {
    List {
      Section {
        Text(services.unreadCount.map { "\($0) unread" } ?? "Unread count unavailable")
          .font(.headline).accessibilityIdentifier("notifications-unread")
        Button("Mark all read") { Task { await services.markRead() } }
          .disabled(services.refreshing || services.unreadCount == nil || services.unreadCount == 0)
          .accessibilityIdentifier("mark-all-notifications-read")
      } footer: {
        Text("Read state is shared by everyone using this deployment.")
      }
      Section {
        if services.alertsEnabled {
          Button("Turn off alerts") { services.disableAlerts() }
        } else {
          Button("Enable alerts") { Task { await services.enableAlerts() } }
        }
        if let error = services.alertError { Text(error).foregroundStyle(.red) }
        if let url = services.pushApprovalURL {
          Button("Approve push for this device") { openURL(url) }
            .accessibilityIdentifier("approve-push-notifications")
        }
        if let error = services.pushError { Text(error).foregroundStyle(.red) }
      } header: {
        Text("Alerts on this device")
      } footer: {
        Text(
          services.pushReady
            ? "Push alerts are enabled. The inbox updates every minute while Iris is active."
            : "Check for new notifications every minute while Iris is active. Existing history is quiet. Push delivery is not confirmed."
        )
      }
      .disabled(services.refreshing || services.changingAlerts)
      if let error = services.notificationError {
        Text(error).foregroundStyle(.red)
        Text("The feed below, if any, is from the last successful refresh.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let feed = services.feed, feed.notifications.isEmpty {
        ContentUnavailableView("No notifications", systemImage: "bell")
          .frame(maxWidth: .infinity)
      }
      ForEach((services.feed?.notifications ?? []).reversed(), id: \.byteExactID) { notification in
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text(notification.title).font(.headline)
            Spacer(minLength: 4)
            if notification.readAt == nil {
              Text("Unread").font(.caption.bold()).foregroundStyle(.tint)
            }
          }
          Label(notification.severity.capitalized, systemImage: severityIcon(notification.severity))
            .font(.caption).foregroundStyle(.secondary)
          Text(notification.body).textSelection(.enabled)
          Text("\(notification.producer) · \(serviceDate(notification.createdAt))")
            .font(.caption).foregroundStyle(.secondary)
          if notification.readAt == nil {
            Button("Mark read") { Task { await services.markRead(id: notification.id) } }
              .disabled(services.refreshing).accessibilityIdentifier("mark-read-" + notification.id)
          }
        }.padding(.vertical, 4)
      }
    }
    .navigationTitle("Notifications")
    .task { await services.refresh() }
  }

  private func severityIcon(_ value: String) -> String {
    switch value {
    case "warning": "exclamationmark.triangle"
    case "error", "critical": "exclamationmark.circle"
    default: "bell"
    }
  }
}

func serviceDate(_ value: String) -> String {
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let date = parser.date(from: value) else { return value }
  return date.formatted(date: .abbreviated, time: .shortened)
}
