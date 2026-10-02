import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = WorkspaceModel()
  @State private var importing = false
  @State private var settings = false
  @State private var options = false
  @State private var showingGraph = false
  @State private var editor: EditorTarget?
  private let demo: Bool

  public init(demo: Bool = false) { self.demo = demo }

  public var body: some View {
    Group {
      if model.client == nil {
        welcome
      } else {
        NavigationSplitView {
          List(selection: $model.table) {
            #if os(macOS)
              Button {
                showingGraph = true
              } label: {
                Label("Schema graph", systemImage: "point.3.connected.trianglepath.dotted")
              }
            #endif
            ForEach(model.tables, id: \.["id"]) { table in
              let id = table["id"]?.text ?? ""
              NavigationLink(value: id) {
                Label(id, systemImage: id == "history" ? "clock" : "tablecells")
              }
            }
          }
          .navigationTitle("Life UI")
          .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
              Text(model.location).font(.caption).foregroundStyle(.secondary)
              if model.isReplica {
                SyncSummary(model: model)
                Button(model.syncing ? "Syncing…" : "Sync now") {
                  Task { await model.synchronize() }
                }
                .disabled(model.syncing).accessibilityIdentifier("sync-now")
              }
              Button("Hub connection") { settings = true }
              Button("Close workspace") { Task { await model.close() } }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
          }
        } detail: {
          #if os(macOS)
            if showingGraph, let catalog = model.catalog {
              SchemaGraphView(
                catalog: catalog, groups: model.groups,
                openTable: { table in
                  model.table = table
                  showingGraph = false
                }, saveGroups: model.saveGroups
              )
              .navigationTitle("Schema graph")
            } else {
              records
            }
          #else
            records
          #endif
        }
        .onChange(of: model.table) { showingGraph = false }
      }
    }
    .task { if demo { await model.open(demo: true) } else { await model.resumeConnection() } }
    .task(id: "\(model.services.generation)|\(scenePhase == .active)") {
      guard scenePhase == .active else { return }
      await model.services.poll()
    }
    .task(id: model.queryKey) { await model.reload() }
    .sheet(item: $editor) { target in
      RecordEditor(
        model: model, original: target.row, context: target.context, onSaved: { editor = nil })
    }
    .sheet(isPresented: $settings) { HubConnectionView(model: model) }
    .sheet(isPresented: $options) { WorkspaceOptionsView(model: model) }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): Task { await model.open(url: url) }
      case .failure(let error): model.error = error.localizedDescription
      }
    }
  }

  private var welcome: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.tint)
        Text("Your workspace, locally.").font(.largeTitle.bold())
        Text(
          "Browse your catalog, write a note, and keep its Markdown source. Work locally or connect a hub to sync across devices."
        )
        .foregroundStyle(.secondary)
        Button("Connect to hub") { settings = true }.buttonStyle(.borderedProminent)
        Button("Open local workspace") { Task { await model.open() } }
          .buttonStyle(.borderedProminent).accessibilityIdentifier("open-local")
        Button("Try sample workspace") { Task { await model.open(demo: true) } }
          .accessibilityIdentifier("open-sample")
        #if os(macOS)
          Button("Open a local database…") { importing = true }
        #endif
        Text("A new local workspace includes a sample note. The sample preview is temporary.")
          .font(.caption).foregroundStyle(.secondary)
        if model.loading { ProgressView() }
        if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
      .disabled(model.loading)
      .padding(32).frame(maxWidth: 560, alignment: .leading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Life UI")
    }
  }

  private var records: some View {
    List {
      if model.isReplica, let result = model.syncResult,
        !result.rejected.isEmpty || !result.skipped.isEmpty
      {
        SyncDetails(model: model)
      }
      if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if let purpose = model.tables.first(where: { $0["id"]?.text == model.table })?["purpose"]?
        .text.nonempty
      {
        Text(purpose).font(.callout).foregroundStyle(.secondary)
      }
      if model.rows.isEmpty && !model.loading {
        ContentUnavailableView(
          model.trash ? "Trash is empty" : "No records", systemImage: "tray",
          description: Text(
            model.search.isEmpty && model.filters.isEmpty
              ? "Create a record to get started." : "Try a different search or filter."))
      }
      ForEach(model.rows) { row in
        Button {
          editor = EditorTarget(row: row.record, context: model.editingContext)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(row.label).foregroundStyle(.primary).font(.headline).lineLimit(2)
            if let date = row.record["updated_at"]?.text {
              Text(date).font(.caption).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(
            .rect)
        }.buttonStyle(.plain)
      }
      if model.canLoadMore { Button("Load more") { Task { await model.reload(more: true) } } }
      if model.loading { ProgressView().frame(maxWidth: .infinity) }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        if model.isReplica { SyncSummary(model: model) }
        Button {
          options = true
        } label: {
          HStack {
            Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
            Spacer()
            if !model.sortColumn.isEmpty {
              Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
            }
            if !model.filters.isEmpty { Text("\(model.filters.count) active") }
          }
        }.accessibilityIdentifier("view-options")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal).padding(.vertical, 8)
      .background(.regularMaterial)
    }
    .navigationTitle(model.table ?? "Workspace")
    .searchable(text: $model.search, prompt: "Search records")
    .refreshable { await model.reload() }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if model.isReplica {
          Button {
            Task { await model.synchronize() }
          } label: {
            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(model.syncing).accessibilityIdentifier("sync-now")
        }
        Button {
          settings = true
        } label: {
          Label("Hub connection", systemImage: "gearshape")
        }
        Button {
          model.trash.toggle()
        } label: {
          Label(
            model.trash ? "Show active records" : "Show trash",
            systemImage: model.trash ? "tray" : "trash")
        }.accessibilityIdentifier("toggle-trash")
        if model.canWrite && !model.trash {
          Button {
            editor = EditorTarget(row: nil, context: model.editingContext)
          } label: {
            Label("New record", systemImage: "plus")
          }
          .accessibilityIdentifier("new-record")
        }
      }
    }
  }
}

private struct EditorTarget: Identifiable {
  let id = UUID()
  let row: WorkspaceRecord?
  let context: WorkspaceEditingContext?
}

private struct RecordEditor: View {
  let model: WorkspaceModel
  let original: WorkspaceRecord?
  let context: WorkspaceEditingContext?
  let onSaved: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft: RecordDraft
  @State private var saving = false
  @State private var discard = false
  @State private var failure: String?
  @State private var violations: [Violation] = []
  @FocusState private var focusedField: String?

  init(
    model: WorkspaceModel, original: WorkspaceRecord?, context: WorkspaceEditingContext?,
    onSaved: @escaping () -> Void
  ) {
    self.model = model
    self.original = original
    self.context = context
    self.onSaved = onSaved
    _draft = State(initialValue: RecordDraft(properties: model.properties, original: original))
  }

  var body: some View {
    NavigationStack {
      Form {
        if !model.rules.isEmpty {
          Section("Catalog rules") {
            ForEach(model.rules, id: \.["id"]) { rule in
              Text(rule["text"]?.text ?? rule["id"]?.text ?? "")
            }
          }
        }
        if model.canWrite && !model.trash {
          ForEach(draft.fields) { field in
            Section {
              FieldInput(
                field: field,
                workspace: context?.workspace,
                focus: $focusedField,
                value: Binding(
                  get: { draft.values[field.id] ?? "" }, set: { draft.values[field.id] = $0 }))
              ForEach(violations.filter { $0.col == field.id }, id: \.rule) { violation in
                Text(violation.message).foregroundStyle(.red).font(.callout)
              }
            } header: {
              Text(field.label)
            } footer: {
              Text(field.help)
            }
          }
        }
        if let original {
          Section("Record") {
            ForEach(original.keys.sorted(), id: \.self) { key in
              if !draft.fields.contains(where: { $0.id == key }) || !model.canWrite || model.trash {
                LabeledContent(key) { Text(original[key]?.text ?? "").textSelection(.enabled) }
              }
            }
          }
          if model.canWrite {
            Section {
              Button(
                model.trash ? "Restore record" : "Move to trash",
                role: model.trash ? nil : .destructive
              ) {
                var patch: WorkspaceRecord = ["deleted_at": model.trash ? .null : .bool(true)]
                patch["id"] = original["id"]
                save(patch)
              }.accessibilityIdentifier("trash-record")
            }
          }
        }
        if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("record-form")
      .navigationTitle(original == nil ? "New record" : "Record")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { if dirty { discard = true } else { dismiss() } }
        }
        if model.canWrite && !model.trash {
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save(draft.patch) }.disabled(saving).accessibilityIdentifier(
              "save-record")
          }
        }
      }
      .disabled(saving)
      .interactiveDismissDisabled(saving || dirty)
      .confirmationDialog(
        "Discard unsaved changes?", isPresented: $discard, titleVisibility: .visible
      ) {
        Button("Discard changes", role: .destructive) { dismiss() }
        Button("Keep editing", role: .cancel) {}
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 560)
    #endif
  }

  private var dirty: Bool { draft.patch.keys.contains { $0 != "id" } }

  private func save(_ patch: WorkspaceRecord) {
    saving = true
    failure = nil
    violations = []
    Task {
      do {
        try await model.save(patch, original: original, context: context)
        onSaved()
      } catch let error as WorkspaceError {
        failure = error.message
        violations = error.violations
      } catch { failure = error.localizedDescription }
      saving = false
    }
  }
}

private struct FieldInput: View {
  let field: CatalogField
  let workspace: NativeWorkspace?
  let focus: FocusState<String?>.Binding
  @Binding var value: String

  var body: some View {
    Group {
      if ["ref", "multi_ref"].contains(field.type) {
        if let workspace, field.property["ref_table"]?.text.nonempty != nil {
          ReferenceField(
            field: field, value: $value, workspace: workspace, onOpen: { focus.wrappedValue = nil })
        } else {
          Text("Reference choices are unavailable. The original value has been preserved.")
            .foregroundStyle(.secondary)
        }
      } else if field.type == "markdown" {
        NavigationLink {
          MarkdownEditorScreen(value: $value, label: field.label)
            .onAppear { focus.wrappedValue = nil }
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            Text("Edit Markdown")
            if !value.isEmpty {
              Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
          }
        }.accessibilityIdentifier("field-\(field.id)")
      } else if ["json", "multi_select"].contains(field.type) {
        VStack(alignment: .leading, spacing: 8) {
          Text("JSON source").font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $value).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
            .focused(focus, equals: field.id)
            .accessibilityLabel(field.label).accessibilityIdentifier("field-\(field.id)")
        }
      } else if field.type == "bool" {
        Picker(field.label, selection: $value) {
          Text("Not set").tag("")
          Text("True").tag("true")
          Text("False").tag("false")
        }.accessibilityIdentifier("field-\(field.id)")
      } else if field.type == "select" && !field.options.isEmpty
        && field.property["options_sql"]?.text.nonempty == nil
      {
        Picker(field.label, selection: $value) {
          Text(field.property["default_value"]?.text.nonempty.map { "Default: \($0)" } ?? "Not set")
            .tag("")
          ForEach(Array(Set(field.options + (value.isEmpty ? [] : [value]))).sorted(), id: \.self) {
            Text($0).tag($0)
          }
        }.accessibilityIdentifier("field-\(field.id)")
      } else {
        TextField(field.label, text: $value, axis: .vertical)
          .focused(focus, equals: field.id)
          .accessibilityIdentifier("field-\(field.id)")
          .autocorrectionDisabled(field.type != "text")
      }
    }
  }
}

#Preview { WorkspaceView(demo: true) }
