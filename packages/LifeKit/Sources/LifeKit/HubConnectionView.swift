import SwiftUI

struct HubConnectionView: View {
  let model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var endpoint = ""
  @State private var token = ""
  @State private var connecting = false
  @State private var failure: String?

  var body: some View {
    NavigationStack {
      Form {
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
          SecureField("Scoped token", text: $token).autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("hub-token")
        } header: {
          Text("Connection")
        } footer: {
          Text(
            "Use the URL and scoped client token issued by your hub. Credentials are saved in this device’s Keychain. Sync uses a separate local replica."
          )
        }
        Section {
          Button(connecting ? "Connecting…" : "Save and sync") { connect() }
            .disabled(connecting || endpoint.isEmpty || token.isEmpty)
          if model.connection != nil {
            Button("Forget saved connection", role: .destructive) {
              do {
                try model.forgetConnection()
                dismiss()
              } catch { failure = error.localizedDescription }
            }.disabled(connecting)
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
          Button("Done") { dismiss() }.disabled(connecting)
        }
      }
      .interactiveDismissDisabled(connecting)
      .task {
        endpoint = model.connection?.endpoint ?? ""
        token = model.connection?.token ?? ""
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 360)
    #endif
  }
  private func connect() {
    connecting = true
    failure = nil
    Task {
      do {
        try await model.connect(
          HubCredentials(
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token))
        dismiss()
      } catch { failure = error.localizedDescription }
      connecting = false
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
      if model.syncing {
        Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
      } else if let result = model.syncResult {
        Text("Last sync: \(result.pulled) received, \(result.pushed) sent.")
      } else {
        Text("Local replica. Sync when connected.")
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
        if !result.skipped.isEmpty {
          Text("Not downloaded: \(result.skipped.joined(separator: ", "))")
        }
      }
    }.font(.caption).foregroundStyle(.secondary)
  }
}
