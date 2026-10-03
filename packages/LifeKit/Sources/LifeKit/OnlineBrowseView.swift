import SwiftUI

struct OnlineBrowseView: View {
  @Bindable var model: OnlineBrowseModel
  let fields: [CatalogField]
  @Environment(\.dismiss) private var dismiss
  @FocusState private var lookupFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Read-only · Not saved on this device")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("online-read-only-notice")
          HStack {
            TextField("Record ID", text: $model.recordID)
              .textFieldStyle(.roundedBorder).autocorrectionDisabled()
              .focused($lookupFocused).onSubmit(findID)
              #if os(iOS)
                .textInputAutocapitalization(.never).submitLabel(.search)
              #endif
              .accessibilityIdentifier("online-record-id")
            Button("Find ID", action: findID)
              .disabled(model.recordID.isEmpty || model.loading || model.opening != nil)
              .accessibilityIdentifier("online-find-id")
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
        if let error = model.openError {
          Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
        }
        List {
          if model.rows.isEmpty && !model.loading && model.error == nil {
            ContentUnavailableView(
              "No online records", systemImage: "cloud",
              description: Text("Refresh to check for new records on the hub."))
          }
          ForEach(model.rows) { row in
            Button {
              Task { await model.open(row) }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(row.label).foregroundStyle(.primary)
                  if row.deleted { Text("Deleted").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.opening == row.id {
                  ProgressView()
                } else {
                  Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
              }.frame(minHeight: 36).contentShape(.rect)
            }
            .buttonStyle(.plain).disabled(model.loading || model.opening != nil)
            .accessibilityIdentifier("online-record-\(row.id)")
          }
        }
        HStack {
          VStack(alignment: .leading) {
            Text(model.rows.count == 1 ? "1 record" : "\(model.rows.count) records")
              .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          }
          Spacer()
          if model.loading || model.opening != nil {
            ProgressView().accessibilityLabel("Loading online records")
          }
          if model.nextCursor != nil || model.error != nil {
            Button(model.error == nil ? "Load more" : "Try again") {
              Task { await model.reload(more: model.nextCursor != nil) }
            }.disabled(model.loading || model.opening != nil)
              .accessibilityIdentifier("online-load-more")
          }
        }.padding().background(.bar)
      }
      .navigationTitle("Online \(model.table)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            model.cancel()
            dismiss()
          }.accessibilityIdentifier("close-online")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
            .disabled(model.loading || model.opening != nil)
        }
      }
      .navigationDestination(item: $model.selected) { row in
        OnlineRecordView(row: row, fields: fields)
      }
      .task { await model.reload() }
    }
    .onDisappear { model.cancel() }
    #if os(macOS)
      .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 640)
    #endif
  }

  private func findID() {
    guard !model.recordID.isEmpty, !model.loading, model.opening == nil else { return }
    lookupFocused = false
    Task { await model.open(id: model.recordID) }
  }
}

private struct OnlineRecordView: View {
  let row: CoreRemoteRecord
  let fields: [CatalogField]

  // Include uncatalogued returned values without manufacturing editable fields.
  private var columns: [String] {
    fields.map(\.id).filter { row.record[$0] != nil }
      + row.record.keys.filter { key in !fields.contains { $0.id == key } }.sorted()
  }

  var body: some View {
    Form {
      Section {
        Label("Online · Read-only", systemImage: "cloud")
        if row.deleted {
          Text("This record is deleted on the hub.").accessibilityIdentifier(
            "online-record-deleted")
        }
      }
      ForEach(columns, id: \.self) { column in
        let field = fields.first { $0.id == column }
        let label = field?.label ?? column
        let value = row.record[column]?.text ?? ""
        Section(label) {
          if field?.type == "markdown" {
            NavigationLink {
              OnlineMarkdownView(value: value, label: label)
            } label: {
              Text(value.isEmpty ? "Empty Markdown" : value).lineLimit(3)
            }.accessibilityIdentifier("online-markdown-\(column)")
          } else {
            Text(value.isEmpty ? "Empty" : value).textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(row.label)
  }
}

private struct OnlineMarkdownView: View {
  @State private var session: MarkdownEditorSession
  init(value: String, label: String) {
    _session = State(
      initialValue: MarkdownEditorSession(value: value, label: label, readOnly: true))
  }
  var body: some View {
    VStack(spacing: 0) {
      Text("Online · Read-only").font(.caption).foregroundStyle(.secondary).padding()
      if let failure = session.failure {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text(failure).foregroundStyle(.secondary)
            Text(session.document.value).font(.body.monospaced()).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
      } else {
        MarkdownWebView(session: session)
      }
    }
    .navigationTitle(session.document.label)
    .onDisappear { session.invalidate() }
  }
}
