import SwiftUI

struct WidgetSettingsView: View {
  let model: WorkspaceModel
  let settings: NativeWidgetSettings
  @Environment(\.dismiss) private var dismiss
  @State private var table = ""
  @State private var viewID = ""
  @State private var views: [CoreSavedViewRecord] = []
  @State private var loading = false
  @State private var failure: String?
  @State private var resetConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Choose which tables and saved views may appear in widgets. Widgets read a protected copy of local records.")
          Text("Home Screen widgets show record titles. Lock Screen widgets show counts and generic labels.")
            .foregroundStyle(.secondary)
        }
        if settings.unreadable {
          Section {
            Text(settings.error ?? "Widget settings could not be read.")
            Button("Reset widget settings", role: .destructive) { resetConfirmation = true }
          }
        } else {
          Section("Enabled sources") {
            if settings.selections.isEmpty { Text("No sources enabled").foregroundStyle(.secondary) }
            ForEach(settings.selections) { selection in
              HStack {
                VStack(alignment: .leading) {
                  Text(selection.table).accessibilityIdentifier("widget-enabled-" + selection.table)
                  if selection.viewID != nil {
                    Text("Saved view").font(.caption).foregroundStyle(.secondary)
                  }
                }
                Spacer()
                Button {
                  Task {
                    _ = await settings.setSelections(
                      settings.selections.filter { $0.id != selection.id }, partial: model.isReplica)
                  }
                } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                  .buttonStyle(.borderless).accessibilityLabel("Remove \(selection.table) from widgets")
                  .accessibilityIdentifier("widget-remove-" + selection.table)
              }
            }
            Button("Refresh widget data") { Task { await settings.refresh(partial: model.isReplica) } }
              .disabled(settings.selections.isEmpty)
          }.disabled(settings.busy)
          Section("Add a source") {
            Picker("Table", selection: $table) {
              ForEach(model.tables.compactMap { $0["id"]?.text }, id: \.self) {
                Text($0).tag($0)
              }
            }
            Picker("View", selection: $viewID) {
              Text("All active records").tag("")
              ForEach(views, id: \.id) { Text($0.name).tag($0.id) }
            }.disabled(loading)
            Button("Enable source") {
              let selection = NativeWidgetSelection(table: table, viewID: viewID.isEmpty ? nil : viewID)
              guard !settings.selections.contains(where: { $0.id == selection.id }) else { return }
              Task { _ = await settings.setSelections(settings.selections + [selection], partial: model.isReplica) }
            }
            .disabled(table.isEmpty || loading || settings.selections.count >= 32)
            .accessibilityIdentifier("widget-enable-source")
          }.disabled(settings.busy)
        }
        #if os(iOS)
          if let integrations = model.integrations {
            IntegrationSettingsSections(model: model, widgets: settings, settings: integrations)
          }
        #endif
        if settings.busy { ProgressView("Preparing widget data") }
        if let message = failure ?? settings.error {
          Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("widget-settings-error") }
        }
        Section {
          Text("Add a Life UI widget from the Home Screen widget gallery, then edit it to choose an enabled source. Today uses the selected saved view’s time zone and day boundary. Stale or partial results are labeled.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Widgets and Search")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task(id: table) {
        if table.isEmpty { table = model.table ?? model.tables.first?["id"]?.text ?? ""; return }
        guard let workspace = model.client else { return }
        let selected = table
        loading = true
        views = []
        viewID = ""
        defer { if table == selected { loading = false } }
        do {
          let result = try await workspace.listViews(table: selected)
          guard !Task.isCancelled, model.client === workspace, table == selected else { return }
          views = result.views.filter { $0.deletedAt == nil && $0.unavailable == nil && $0.definition != nil }
          failure = nil
        } catch {
          if !Task.isCancelled { failure = error.localizedDescription }
        }
      }
      .confirmationDialog("Reset widget settings?", isPresented: $resetConfirmation, titleVisibility: .visible) {
        Button("Reset", role: .destructive) {
          do { try settings.resetUnreadSettings() } catch { failure = error.localizedDescription }
        }
      } message: { Text("The unreadable file will be preserved and existing widget access removed.") }
    }
  }
}
