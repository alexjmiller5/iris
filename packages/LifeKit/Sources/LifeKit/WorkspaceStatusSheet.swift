import SwiftUI

struct WorkspaceStatusSheet: View {
  let model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Workspace") {
          Text(model.location).textSelection(.enabled)
        }
        if model.isReplica {
          Section("Sync") {
            SyncSummary(model: model)
            SyncDetails(model: model)
            Button("Sync now") { Task { await model.synchronize() } }
              .disabled(model.syncing).accessibilityIdentifier("sync-now")
          }
        }
        if let error = model.error {
          Section("Needs attention") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
      }
      .navigationTitle("Workspace status")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("status-done")
        }
      }
    }
  }
}
