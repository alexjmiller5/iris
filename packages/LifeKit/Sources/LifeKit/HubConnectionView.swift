import SwiftUI

struct HubConnectionView: View {
  let model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var endpoint = ""
  @State private var token = ""
  @State private var connecting = false
  @State private var failure: String?
  @State private var deviceName = "Life UI"
  @State private var manual = false
  @State private var enrollment: EnrollmentModel?
  @State private var active = true

  private var busy: Bool {
    connecting || enrollment?.phase == .waiting || enrollment?.phase == .installing
  }

  var body: some View {
    NavigationStack {
      Form {
        if let context = model.downloadContext {
          Section {
            NavigationLink {
              DownloadsView(model: model, context: context)
            } label: {
              Label("Downloads", systemImage: "arrow.down.circle")
            }.accessibilityIdentifier("hub-downloads")
          }
        }
        if model.client != nil {
          Section {
            NavigationLink {
              BackupView(model: model)
            } label: {
              Label("Backup", systemImage: "externaldrive")
            }.accessibilityIdentifier("backup-settings")
          }
        }
        if model.services.connected {
          Section("This deployment") {
            NavigationLink {
              HubUsageView(services: model.services)
            } label: {
              Label("Usage", systemImage: "chart.bar")
            }.accessibilityIdentifier("hub-usage")
            NavigationLink {
              HubNotificationsView(services: model.services)
            } label: {
              Label(
                model.services.unreadCount.map { "Notifications (\($0))" } ?? "Notifications",
                systemImage: "bell"
              )
              .frame(minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("hub-notifications")
          }
        }
        Section {
          TextField("Hub URL", text: $endpoint).autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never).keyboardType(.URL)
            #endif
            .accessibilityIdentifier("hub-endpoint")
            .disabled(busy)
        } header: {
          Text("Connection")
        } footer: {
          Text(
            "Approve this device in your hub. Its credential stays in this device’s Keychain, and sync uses a separate local replica."
          )
        }
        HubApprovalSection(
          enrollment: enrollment, deviceName: $deviceName,
          disabled: connecting || endpoint.isEmpty, begin: beginApproval)
        Section {
          DisclosureGroup("Use existing token", isExpanded: $manual) {
            SecureField("Scoped token", text: $token).autocorrectionDisabled()
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
              .accessibilityIdentifier("hub-token")
            Button(connecting ? "Connecting…" : "Connect") { connect() }
              .disabled(busy || endpoint.isEmpty || token.isEmpty)
            Text(
              "Use a dedicated full-scope device token. Operator credentials cannot connect a replica."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.disabled(busy)
          if model.connection != nil {
            Button("Forget saved connection", role: .destructive) {
              connecting = true
              Task {
                defer { connecting = false }
                do {
                  try await model.forgetConnection()
                  dismiss()
                } catch { failure = error.localizedDescription }
              }
            }.disabled(busy)
            Text(
              "The local replica stays on this device. Reconnect to the same hub to resume sync."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      }
      .formStyle(.grouped)
      .navigationTitle("Hub connection")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }.disabled(busy)
        }
      }
      .interactiveDismissDisabled(busy)
      .task {
        active = true
        endpoint = model.connection?.endpoint ?? ""
      }
      .onChange(of: model.workspaceGeneration) {
        if enrollment?.phase == .waiting { Task { await enrollment?.cancel() } }
      }
      .onDisappear {
        active = false
        if enrollment?.phase == .waiting { Task { await enrollment?.cancel() } }
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 360)
    #endif
  }
  private func connect() {
    connecting = true
    failure = nil
    let generation = model.workspaceGeneration
    Task {
      do {
        try await model.connect(
          HubCredentials(
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token),
          isCurrent: { active && model.workspaceGeneration == generation })
        dismiss()
      } catch { failure = error.localizedDescription }
      connecting = false
    }
  }

  private func beginApproval() {
    failure = nil
    let generation = model.workspaceGeneration
    let next = EnrollmentModel(
      isCurrent: { active && model.workspaceGeneration == generation },
      install: { credentials, fingerprint, current in
        try await model.connect(
          credentials, expectedFingerprint: fingerprint,
          synchronizeAfter: false, isCurrent: current)
      })
    enrollment = next
    Task {
      await next.start(
        endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), name: deviceName)
      if next.phase == .connected, active {
        Task { await model.synchronize() }
        dismiss()
      }
    }
  }
}

private struct HubApprovalSection: View {
  let enrollment: EnrollmentModel?
  @Binding var deviceName: String
  let disabled: Bool
  let begin: () -> Void
  @Environment(\.openURL) private var openURL

  var body: some View {
    Section("Approve a device") {
      if let enrollment, enrollment.phase == .waiting || enrollment.phase == .installing {
        if let code = enrollment.approvalCode {
          LabeledContent("Approval code", value: code).accessibilityIdentifier("enrollment-code")
        }
        if let url = enrollment.approvalURL {
          Button("Open approval link") { openURL(url) }
            .accessibilityIdentifier("enrollment-link").accessibilityValue(url.absoluteString)
        }
        if let status = enrollment.status { Text(status).font(.callout) }
        Button("Cancel approval", role: .cancel) { Task { await enrollment.cancel() } }
          .disabled(enrollment.phase == .installing).accessibilityIdentifier("cancel-enrollment")
      } else {
        TextField("Device name", text: $deviceName).accessibilityIdentifier("hub-device-name")
        Button("Request approval", action: begin).accessibilityIdentifier("begin-enrollment")
          .disabled(disabled || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = enrollment?.failure {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let cleanup = enrollment?.cleanupMessage {
        Text(cleanup).font(.callout).textSelection(.enabled)
      }
    }
  }
}

struct SyncSummary: View {
  let model: WorkspaceModel
  @State private var notifications = false
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let status = model.syncStatus {
        Text(
          status.pendingUiEdits == 0
            ? "No local edits waiting to sync."
            : (status.pendingUiEdits == 1
              ? "1 record waiting to sync." : "\(status.pendingUiEdits) records waiting to sync."))
        if status.rejected > 0 {
          Text("\(status.rejected) records need attention.").foregroundStyle(.red)
        }
        if let timestamp = status.lastSuccessfulSync { Text("Last successful sync: \(timestamp)") }
      }
      if let result = model.syncResult {
        Text("Last sync: \(result.pulled) received, \(result.pushed) sent.")
      } else {
        Text("Local replica. Changes sync automatically when connected.")
      }
      if model.services.connected {
        Button {
          notifications = true
        } label: {
          Label(
            model.services.unreadCount.map { "Notifications (\($0))" } ?? "Notifications",
            systemImage: "bell")
        }.buttonStyle(.borderless).accessibilityIdentifier("open-notifications")
      }
    }.font(.caption).foregroundStyle(.secondary)
      .sheet(isPresented: $notifications) {
        NavigationStack {
          HubNotificationsView(services: model.services)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Done") { notifications = false }
              }
            }
        }
        #if os(macOS)
          .frame(minWidth: 520, minHeight: 480)
        #endif
      }
  }
}

struct SyncDetails: View {
  let model: WorkspaceModel
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let result = model.syncResult {
        if !result.rejected.isEmpty {
          Text("\(result.rejected.count) changes need attention. Local edits are kept.")
            .foregroundStyle(.red)
          ForEach(Array(result.rejected.enumerated()), id: \.offset) { _, record in
            Text(
              record["errors"]?.text ?? record["message"]?.text ?? record["id"]?.text
                ?? "Rejected change"
            )
            .textSelection(.enabled)
          }
        }
      }
      if !model.skippedTables.isEmpty {
        Text("Not downloaded: \(model.skippedTables.joined(separator: ", "))")
      }
    }.font(.caption).foregroundStyle(.secondary)
  }
}
