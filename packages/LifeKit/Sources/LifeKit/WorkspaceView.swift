import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = WorkspaceModel()
  @State private var importing = false
  @State private var settings = false
  @State private var options = false
  @State private var savedViews = false
  @State private var showingGraph = false
  @State private var tableSearchPresented = false
  @State private var editor: EditorTarget?
  @State private var online: OnlineBrowseModel?
  @State private var quickFind: QuickFindModel?
  @State private var pendingSearchEditor: (target: EditorTarget, generation: Int)?
  @State private var pendingReferenceEditor:
    (destination: ReferenceDestination, source: WorkspaceEditingContext, generation: Int)?
  private let demo: Bool

  public init(demo: Bool = false) { self.demo = demo }

  public var body: some View {
    Group {
      if model.client == nil {
        welcome
      } else {
        NavigationSplitView {
          List(selection: $model.table) {
            Button(action: showQuickFind) {
              Label("Find records", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canFind)
            .accessibilityIdentifier("quick-find-sidebar")
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
    .sheet(item: $editor, onDismiss: finishEditorDismissal) { target in
      RecordEditor(
        model: model, original: target.row, context: target.context, recovered: target.recovered,
        isCurrent: { editor?.id == target.id },
        onReference: { destination in
          guard editor?.id == target.id, let source = target.context,
            source.workspace === model.client, source.table == model.table
          else { return }
          pendingReferenceEditor = (destination, source, model.workspaceGeneration)
          editor = nil
        }, onSaved: { editor = nil })
    }
    .sheet(
      item: $online,
      onDismiss: {
        online?.cancel()
        online = nil
      }
    ) { browser in
      OnlineBrowseView(model: browser, fields: model.properties.map(CatalogField.init))
    }
    .onChange(of: model.table) {
      online?.cancel()
      online = nil
    }
    .onChange(of: model.isReplica) {
      online?.cancel()
      online = nil
    }
    .sheet(isPresented: $settings) { HubConnectionView(model: model) }
    .sheet(isPresented: $options) { WorkspaceOptionsView(model: model) }
    .sheet(isPresented: $savedViews) { SavedViewsView(model: model) }
    .sheet(item: $quickFind, onDismiss: openSearchEditor) { find in
      QuickFindView(model: find, incomplete: !model.skippedTables.isEmpty) {
        hit, row in
        guard find.isCurrent, quickFind === find, editor == nil, let client = model.client else {
          return
        }
        do {
          let context = try model.activateSearchTable(
            hit.table, workspace: client, generation: model.workspaceGeneration)
          pendingSearchEditor = (
            EditorTarget(row: row.record, context: context), model.workspaceGeneration
          )
          showingGraph = false
          quickFind = nil
        } catch { model.error = error.localizedDescription }
      }
    }
    .onChange(of: model.workspaceGeneration) {
      online?.cancel()
      online = nil
      quickFind?.cancel()
      quickFind = nil
      pendingSearchEditor = nil
      pendingReferenceEditor = nil
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): Task { await model.open(url: url) }
      case .failure(let error): model.error = error.localizedDescription
      }
    }
  }

  private var canFind: Bool {
    model.client != nil && editor == nil && online == nil && quickFind == nil
      && pendingSearchEditor == nil
      && !settings && !options && !savedViews && !importing
  }

  private func showQuickFind() {
    guard canFind else { return }
    quickFind = model.makeQuickFind()
  }

  private func openSearchEditor() {
    guard let pending = pendingSearchEditor else { return }
    pendingSearchEditor = nil
    guard editor == nil, pending.generation == model.workspaceGeneration,
      pending.target.context?.workspace === model.client,
      pending.target.context?.table == model.table
    else { return }
    editor = pending.target
  }

  private func finishEditorDismissal() {
    model.refreshDrafts()
    guard let pending = pendingReferenceEditor else { return }
    pendingReferenceEditor = nil
    guard editor == nil, pending.generation == model.workspaceGeneration,
      pending.source.workspace === model.client, pending.source.table == model.table
    else { return }
    do {
      tableSearchPresented = false
      let context = try model.activateSearchTable(
        pending.destination.table,
        workspace: pending.source.workspace, generation: pending.generation)
      showingGraph = false
      editor = EditorTarget(row: pending.destination.row.record, context: context)
    } catch { model.error = error.localizedDescription }
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
      if let action = model.undoAction {
        Button {
          let context = model.editingContext
          Task {
            do { try await model.undo(action, context: context) } catch {
              model.error = error.localizedDescription
            }
          }
        } label: {
          Label("Undo last saved change", systemImage: "arrow.uturn.backward")
        }.disabled(model.undoing || !canFind).accessibilityIdentifier("undo-saved-change")
      }
      ForEach(model.recoverableDrafts.filter { $0.table == model.table }) { saved in
        Button {
          guard let context = model.editingContext else { return }
          Task {
            do {
              let current = try await model.recoveryRecord(saved, context: context)
              editor = EditorTarget(row: current, context: context, recovered: saved)
            } catch { model.error = error.localizedDescription }
          }
        } label: {
          VStack(alignment: .leading) {
            Label("Resume unsaved draft", systemImage: "square.and.pencil")
            if let field = saved.draft.fields.first,
              let value = saved.draft.values[field.id]?.nonempty
            {
              Text(value).lineLimit(1)
            }
            Text(saved.modifiedAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
          }
        }.accessibilityIdentifier("resume-unsaved-draft")
      }
      if model.isReplica,
        model.syncResult?.rejected.isEmpty == false || !model.skippedTables.isEmpty
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
      ForEach(model.rows, id: \.byteExactID) { row in
        Button {
          editor = EditorTarget(row: row.record, context: model.editingContext)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(row.label).foregroundStyle(.primary).font(.headline).lineLimit(2)
            if let columns = model.visibleRecordColumns {
              ForEach(columns, id: \.self) { column in
                LabeledContent(
                  model.properties.first { $0["col"]?.text == column }?["label"]?.text ?? column
                ) {
                  Text(row.record[column]?.text ?? "").lineLimit(2)
                }.font(.caption).foregroundStyle(.secondary)
              }
            } else if let date = row.record["updated_at"]?.text {
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
        if let message = model.partialTableNotice, let context = model.downloadContext,
          let table = model.table
        {
          PartialReplicaNotice(model: model, context: context, table: table, message: message)
        }
        if model.isReplica, model.table != nil {
          Button {
            guard canFind else { return }
            tableSearchPresented = false
            online = model.makeOnlineBrowser()
          } label: {
            Label("Browse online", systemImage: "cloud")
          }.disabled(!canFind).accessibilityIdentifier("browse-online")
        }
        if let reason = model.editingUnavailable {
          Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            .accessibilityIdentifier("editing-availability")
        }
        HStack {
          Button {
            savedViews = true
          } label: {
            Label("Views", systemImage: "rectangle.stack")
          }.disabled(editor != nil || model.client == nil)
            .accessibilityIdentifier("saved-views")
          Button {
            options = true
          } label: {
            HStack {
              Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
              if !model.sortColumn.isEmpty {
                Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
              }
              if !model.filters.isEmpty { Text("\(model.filters.count) active") }
            }
          }.accessibilityIdentifier("view-options")
          Spacer()
          Button(action: showQuickFind) { Label("Find", systemImage: "magnifyingglass") }
            .disabled(!canFind).accessibilityIdentifier("quick-find")
        }
        if let applied = model.appliedView {
          Text(applied.name + (model.viewModified ? " · Modified" : ""))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal).padding(.vertical, 8)
      .background(.regularMaterial)
    }
    .navigationTitle(model.table ?? "Workspace")
    .searchable(
      text: $model.search, isPresented: $tableSearchPresented, prompt: "Search this table"
    )
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
  var recovered: StoredEditorDraft? = nil
}

private struct RecordEditor: View {
  let model: WorkspaceModel
  let context: WorkspaceEditingContext?
  let onSaved: () -> Void
  let recordFields: [CatalogField]
  let isCurrent: @MainActor () -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var editor: RecordEditorModel
  @State private var referenceNavigation: ReferenceNavigationModel?
  @State private var confirmReference = false
  @State private var saving = false
  @State private var discard = false
  @State private var actionFailure: String?
  @FocusState private var focusedField: String?

  init(
    model: WorkspaceModel, original: WorkspaceRecord?, context: WorkspaceEditingContext?,
    recovered: StoredEditorDraft?, isCurrent: @escaping @MainActor () -> Bool,
    onReference: @escaping (ReferenceDestination) -> Void, onSaved: @escaping () -> Void
  ) {
    self.model = model
    self.context = context
    self.onSaved = onSaved
    self.isCurrent = isCurrent
    recordFields = model.properties.map(CatalogField.init)
    let source = RecordEditorModel(
      properties: model.properties,
      original: original, table: context?.table ?? "", store: context?.draftStore,
      recovered: recovered
    ) { patch, baseline in
      try await model.save(patch, original: baseline, context: context)
    }
    _editor = State(initialValue: source)
    _referenceNavigation = State(
      initialValue: context.map {
        model.makeReferenceNavigation(
          editor: source, context: $0, isCurrent: isCurrent,
          onOpen: onReference)
      })
  }

  var body: some View {
    NavigationStack {
      Form {
        if let action = model.undoAction {
          Section {
            Button {
              focusedField = nil
              Task {
                do {
                  try await editor.performUndo(action, isCurrent: editorIsCurrent) {
                    try await model.undo(action, context: context)
                  }
                  actionFailure = nil
                } catch { actionFailure = error.localizedDescription }
              }
            } label: {
              Label("Undo last saved change", systemImage: "arrow.uturn.backward")
            }
            .disabled(
              editor.saving || editor.recovery != nil || editor.needsReview || model.undoing
            )
            .accessibilityIdentifier("undo-editor")
          }
        }
        if editor.autosavePaused || editor.isTrashed {
          Section {
            Text(editor.status).foregroundStyle(.secondary)
            if editor.isTrashed && model.canWrite, let id = editor.draft.original?["id"] {
              Button("Restore record") { save(["id": id, "deleted_at": .null]) }
                .disabled(editor.recovery != nil || editor.needsReview)
                .accessibilityIdentifier("trash-record")
            }
          }
        }
        if editor.recovery != nil {
          Section("Unsaved draft") {
            Text("Continue your unsaved changes or start with the saved record.")
            ForEach(editor.recoveryChoices) { saved in
              if editor.recoveryChoices.count > 1 {
                Text(saved.modifiedAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
                if let first = saved.draft.fields.first,
                  let value = saved.draft.values[first.id]
                {
                  Text(value).lineLimit(2)
                }
              }
              Button("Resume draft") { editor.resumeDraft(saved) }
              Button("Discard draft", role: .destructive) {
                do { try editor.discardRecovery(saved) } catch {
                  actionFailure = error.localizedDescription
                }
              }
            }
            Button(editor.isNew ? "Start new record" : "Open saved record") {
              editor.openSavedRecord()
            }
            Text("Your unsaved drafts will remain available until you discard them.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if editor.needsReview {
          Section("Review recovered changes") {
            Text(
              "Copy the values you want to keep, then keep the draft and close. Open the saved record to review and paste your changes."
            )
          }
        }
        if !model.rules.isEmpty {
          Section("Catalog rules") {
            ForEach(model.rules, id: \.["id"]) { rule in
              Text(rule["text"]?.text ?? rule["id"]?.text ?? "")
            }
          }
        }
        if let reason = model.editingUnavailable {
          Section { Text(reason).foregroundStyle(.secondary) }
        }
        if model.canWrite && !editor.isTrashed {
          ForEach(editor.draft.fields) { field in
            Section {
              FieldInput(
                field: field, workspace: context?.workspace, focus: $focusedField,
                editor: editor, onOpenReference: openReference,
                undoAction: model.undoAction, undo: { try await model.undo($0, context: context) },
                isCurrent: editorIsCurrent,
                referenceAvailability: referenceAvailability(field),
                value: Binding(
                  get: { editor.draft.values[field.id] ?? "" },
                  set: { editor.setValue($0, for: field.id) }))
              if editor.failure != nil {
                CopyDraftButton(
                  title: "Copy \(field.label)", value: editor.draft.values[field.id] ?? "")
              }
              ForEach(editor.violations.filter { $0.col == field.id }, id: \.rule) { violation in
                Text(violation.message).foregroundStyle(.red).font(.callout)
              }
            } header: {
              Text(field.label)
            } footer: {
              Text(field.help)
            }
            .disabled(editor.recovery != nil)
          }
        }
        if editor.isTrashed && editor.dirty {
          Section("Kept draft") {
            Text("Restore the record first, then review and save these changes.")
            ForEach(editor.draft.fields.filter { editor.draft.patch[$0.id] != nil }) { field in
              LabeledContent(field.label) {
                Text(editor.draft.values[field.id] ?? "").textSelection(.enabled)
              }
              CopyDraftButton(
                title: "Copy \(field.label)", value: editor.draft.values[field.id] ?? "")
            }
          }
        }
        if !editor.draft.unknownValues.isEmpty {
          Section("Unavailable fields") {
            Text("These draft values have been kept and will not be included when saving.")
            ForEach(editor.draft.unknownValues.keys.sorted(), id: \.self) { key in
              LabeledContent(key) {
                Text(editor.draft.unknownValues[key] ?? "").textSelection(.enabled)
              }
              CopyDraftButton(title: "Copy \(key)", value: editor.draft.unknownValues[key] ?? "")
            }
          }
        }
        if let original = editor.draft.original {
          Section("Record") {
            ForEach(original.keys.sorted(), id: \.self) { key in
              if !editor.draft.fields.contains(where: { $0.id == key }) || !model.canWrite
                || editor.isTrashed
              {
                if let field = recordFields.first(where: { $0.id == key }),
                  ["ref", "multi_ref"].contains(field.type), let workspace = context?.workspace,
                  field.property["ref_table"]?.text.nonempty != nil
                {
                  VStack(alignment: .leading, spacing: 8) {
                    Text(field.label)
                    ReferenceField(
                      field: field, value: .constant(original[key]?.text ?? ""),
                      workspace: workspace, canEdit: false,
                      canOpen: !editor.saving,
                      availability: referenceAvailability(field), onOpenRecord: openReference)
                  }
                } else {
                  LabeledContent(key) { Text(original[key]?.text ?? "").textSelection(.enabled) }
                }
              }
            }
          }
          if model.canWrite && !editor.isTrashed {
            Section {
              Button(
                "Move to trash", role: .destructive
              ) {
                save(["id": original["id"]!, "deleted_at": .bool(true)])
              }.accessibilityIdentifier("trash-record").disabled(editor.recovery != nil)
            }
          }
        }
        if let failure = actionFailure ?? editor.failure {
          Section {
            Text(failure).foregroundStyle(.red).textSelection(.enabled)
            if !editor.isNew && editor.recovery == nil && !editor.needsReview
              && !editor.autosavePaused && !editor.isTrashed
            {
              Button("Retry Markdown save") {
                Task {
                  do {
                    try await editor.flushMarkdown(retry: true)
                    actionFailure = nil
                  } catch { actionFailure = error.localizedDescription }
                }
              }.disabled(editor.saving)
            }
          }
        } else if editor.dirty && !editor.isNew && editor.markdownSaved {
          Section { Text("Markdown saved. Other changes are unsaved.").foregroundStyle(.secondary) }
        }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("record-form")
      .navigationTitle(editor.isNew ? "New record" : "Record")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if editor.failure != nil || editor.autosavePaused {
            Button("Keep draft and close") {
              do {
                try editor.keepDraft()
                dismiss()
              } catch { actionFailure = error.localizedDescription }
            }.accessibilityIdentifier("keep-record-draft")
          } else {
            Button("Cancel") {
              if editor.dirty { discard = true } else { dismiss() }
            }.disabled(editor.saving)
          }
        }
        if model.canWrite && !editor.isTrashed {
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }.disabled(
              saving || editor.recovery != nil || editor.needsReview
            )
            .accessibilityIdentifier("save-record")
          }
        }
      }
      .disabled(saving || editor.undoing || referenceNavigation?.loading == true)
      .interactiveDismissDisabled(saving || editor.saving || editor.dirty || editor.recovery != nil)
      .confirmationDialog(
        "Discard unsaved changes?", isPresented: $discard, titleVisibility: .visible
      ) {
        Button("Discard changes", role: .destructive) { discardSavedDraft(close: true) }
        Button("Keep editing", role: .cancel) {}
      }
      .alert(
        referenceNavigation?.error == nil
          ? "Discard unsaved changes and open the related record?" : "Cannot open record",
        isPresented: $confirmReference
      ) {
        if referenceNavigation?.error != nil {
          Button("OK") { referenceNavigation?.cancel() }
        } else {
          Button("Discard changes and open", role: .destructive) {
            Task { _ = await referenceNavigation?.discardAndOpen() }
          }
          Button("Keep editing", role: .cancel) { referenceNavigation?.cancel() }
        }
      } message: {
        if let error = referenceNavigation?.error { Text(error) }
      }
      .onChange(of: referenceNavigation?.confirmation) {
        confirmReference = referenceNavigation?.confirmation != nil
      }
      .onChange(of: referenceNavigation?.error) {
        if referenceNavigation?.error != nil { confirmReference = true }
      }
      .onDisappear { referenceNavigation?.cancel() }
      .onChange(of: model.workspaceGeneration) { referenceNavigation?.cancel() }
      .onChange(of: model.table) { referenceNavigation?.cancel() }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 560)
    #endif
  }

  private func editorIsCurrent() -> Bool {
    isCurrent() && context?.workspace === model.client && context?.table == model.table
  }

  private func referenceAvailability(_ field: CatalogField) -> String? {
    guard let table = field.property["ref_table"]?.text else { return nil }
    if !model.tables.contains(where: { $0["id"]?.text == table }) {
      return "The related table is not available on this device."
    }
    return model.skippedTables.contains(table)
      ? "Some records in this table were skipped during sync. Stored records can still be opened."
      : nil
  }

  private func openReference(table: String, id: String) {
    focusedField = nil
    Task {
      _ = await referenceNavigation?.open(table: table, id: id)
    }
  }

  private func discardSavedDraft(close: Bool) {
    do {
      try editor.discardDraft()
      if close { dismiss() }
    } catch { actionFailure = error.localizedDescription }
  }

  private func save(_ patch: WorkspaceRecord? = nil) {
    saving = true
    actionFailure = nil
    Task {
      do {
        try await editor.saveAll(patch)
        if editor.dirty {
          actionFailure =
            "The saved fields are up to date. Your remaining draft values have been kept."
        } else {
          onSaved()
        }
      } catch { actionFailure = error.localizedDescription }
      saving = false
    }
  }
}

private struct FieldInput: View {
  let field: CatalogField
  let workspace: NativeWorkspace?
  let focus: FocusState<String?>.Binding
  let editor: RecordEditorModel
  let onOpenReference: (String, String) -> Void
  let undoAction: CoreUndoAction?
  let undo: (CoreUndoAction) async throws -> WorkspaceRecord
  let isCurrent: @MainActor () -> Bool
  let referenceAvailability: String?
  @Binding var value: String

  var body: some View {
    Group {
      if ["ref", "multi_ref"].contains(field.type) {
        if let workspace, field.property["ref_table"]?.text.nonempty != nil {
          ReferenceField(
            field: field, value: $value, workspace: workspace, onOpen: { focus.wrappedValue = nil },
            canOpen: !editor.saving, availability: referenceAvailability,
            onOpenRecord: onOpenReference)
        } else {
          Text("Reference choices are unavailable. The original value has been preserved.")
            .foregroundStyle(.secondary)
        }
      } else if field.type == "markdown" {
        NavigationLink {
          MarkdownEditorScreen(
            value: $value, label: field.label, editor: editor,
            undoAction: undoAction, undo: undo, isCurrent: isCurrent
          )
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
