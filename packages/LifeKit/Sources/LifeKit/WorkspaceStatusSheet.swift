import SwiftUI

struct WorkspaceStatusSheet: View {
  let model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var diagnosticsCopied = false
  @State private var diagnosticCopyFailed = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Workspace") {
          Text(model.location).textSelection(.enabled)
          LabeledContent("App version") {
            let version =
              Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
              ?? "?"
            let build =
              Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            Text("\(version) (\(build))")
              .accessibilityIdentifier("app-version")
          }
          Button {
            guard let workspace = model.client else { return }
            do {
              let report = try workspace.diagnosticReport(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                  as? String ?? "",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
              CopyDraftButton.copy(report)
              diagnosticsCopied = true
              diagnosticCopyFailed = false
            } catch {
              diagnosticsCopied = false
              diagnosticCopyFailed = true
            }
          } label: {
            Label(diagnosticsCopied ? "Copied" : "Copy diagnostics", systemImage: "doc.on.doc")
          }
          .disabled(model.client == nil)
          .accessibilityIdentifier("copy-diagnostics")
          .help("Copy timing information without record contents or connection details.")
          if diagnosticCopyFailed {
            Text("Could not copy diagnostics. Try again.").foregroundStyle(.secondary)
          }
        }
        if model.isReplica {
          Section("Sync") {
            SyncSummary(model: model)
            if !model.skippedTables.isEmpty || !(model.syncResult?.rejected.isEmpty ?? true) {
              SyncDetails(model: model)
            }
            if model.syncing {
              if let progress = model.syncProgress {
                LabeledContent("Activity") {
                  Text(progress.phase).accessibilityIdentifier("sync-phase")
                }
                if let table = progress.table {
                  LabeledContent("Table", value: table)
                }
                if progress.page > 0 {
                  LabeledContent("Pages", value: progress.page.formatted())
                }
                LabeledContent("Rows processed", value: progress.processedRows.formatted())
                LabeledContent("Elapsed") {
                  Text(progress.startedAt, style: .timer)
                    .monospacedDigit().accessibilityIdentifier("sync-elapsed")
                }
              }
              Button("Cancel sync") { model.cancelSync() }
                .accessibilityIdentifier("cancel-sync")
            }
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
