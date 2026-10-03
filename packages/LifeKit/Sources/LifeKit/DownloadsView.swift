import SwiftUI

struct DownloadsView: View {
  let model: WorkspaceModel
  let context: ReplicaDownloadContext
  @Environment(\.dismiss) private var dismiss
  @State private var limit: String
  @State private var tables: [String: Bool]
  @State private var failure: String?

  init(model: WorkspaceModel, context: ReplicaDownloadContext) {
    self.model = model
    self.context = context
    _limit = State(initialValue: model.downloadPreferences.maxRows.map(String.init) ?? "")
    _tables = State(initialValue: model.downloadPreferences.tables)
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Rows per table") {
          TextField("Automatic", text: $limit)
            .multilineTextAlignment(.trailing)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .accessibilityIdentifier("download-limit")
        }
      } header: {
        Text("Automatic download limit")
      } footer: {
        Text("Leave blank to use the automatic default. Larger tables stay out of automatic sync.")
      }
      Section {
        ForEach(model.tables, id: \.["id"]) { table in
          let id = table["id"]?.text ?? ""
          if id.hasPrefix("catalog_") {
            LabeledContent(id, value: "Always downloaded")
          } else {
            Picker(
              id,
              selection: Binding(
                get: { tables[id].map { $0 ? "include" : "skip" } ?? "automatic" },
                set: { tables[id] = $0 == "automatic" ? nil : $0 == "include" }
              )
            ) {
              Text("Automatic").tag("automatic")
              Text("Include").tag("include")
              Text("Skip").tag("skip")
            }
            .accessibilityIdentifier("download-table-\(id)")
          }
        }
      } header: {
        Text("Tables")
      } footer: {
        Text(
          "Include downloads a table regardless of size. Skip keeps its existing local rows. Catalogs always download. Changes apply on the next sync."
        )
      }
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
    }
    .formStyle(.grouped)
    .navigationTitle("Downloads")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          do {
            try model.saveDownloads(
              ReplicaPreferences.parse(limit: limit, tables: tables), context: context)
            dismiss()
          } catch { failure = error.localizedDescription }
        }.disabled(model.syncing).accessibilityIdentifier("save-downloads")
      }
    }
  }
}

struct PartialReplicaNotice: View {
  let model: WorkspaceModel
  let context: ReplicaDownloadContext
  let table: String
  let message: String
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message).accessibilityIdentifier("partial-table-notice")
      if model.downloadPreferences.tables[table] != true {
        Button("Include in next sync") {
          do {
            var preferences = model.downloadPreferences
            preferences.tables[table] = true
            try model.saveDownloads(preferences, context: context)
          } catch { failure = error.localizedDescription }
        }
        .frame(minHeight: 44, alignment: .leading)
        .disabled(model.syncing)
        .accessibilityIdentifier("include-table-next-sync")
      }
      if let failure { Text(failure).foregroundStyle(.red) }
    }
    .font(.caption)
    .onChange(of: table) { failure = nil }
  }
}
