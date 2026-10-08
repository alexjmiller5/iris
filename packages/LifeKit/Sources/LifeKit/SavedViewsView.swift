import SwiftUI

struct SavedViewsView: View {
  let model: WorkspaceModel
  let onChoose: (NativeDestination) -> Void
  private let context: WorkspaceEditingContext?
  private let generation: Int
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editingName: Bool
  @State private var name: String
  @State private var error: String?
  @State private var notice: String?
  @State private var loading = true
  @State private var deleting: CoreSavedViewRecord?

  init(model: WorkspaceModel, onChoose: @escaping (NativeDestination) -> Void = { _ in }) {
    self.model = model
    self.onChoose = onChoose
    context = model.editingContext
    generation = model.workspaceGeneration
    _name = State(initialValue: model.appliedView?.name ?? "")
  }

  private var current: Bool {
    context?.workspace === model.client && context?.table == model.table
      && generation == model.workspaceGeneration
  }

  private var writable: Bool {
    model.viewsWriteability?.writable == true && model.savedViewsUnavailable == nil
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            PropertyLayoutView(model: model)
          } label: {
            Label("Properties", systemImage: "slider.horizontal.3")
          }.accessibilityIdentifier("view-properties")
          NavigationLink {
            WorkspaceOptionsView(model: model)
          } label: {
            Label("Layout and actions", systemImage: "square.grid.2x2")
          }.accessibilityIdentifier("view-layout-actions")
        } footer: {
          Text("Changes apply now and save to the current view when you close this sheet.")
        }
        Section {
          // Tables open on a saved view; the transient catalog view is only a fallback.
          if !model.savedViews.contains(where: { $0.unavailable == nil }) {
            Button("All records") { choose(nil) }
          }
          ForEach(model.savedViews, id: \.byteExactID) { saved in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Button(saved.name) { choose(saved) }
                  .disabled(saved.unavailable != nil)
                if let reason = saved.unavailable {
                  Text(reason).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if model.appliedView?.byteExactID == saved.byteExactID {
                Image(systemName: "checkmark").foregroundStyle(.tint)
                  .accessibilityLabel("Applied view")
              }
              if writable, saved.updatedAt != nil {
                Button(role: .destructive) {
                  deleting =
                    model.appliedView?.byteExactID == saved.byteExactID ? model.appliedView : saved
                } label: {
                  Image(systemName: "trash")
                }.accessibilityLabel("Delete \(saved.name)")
              }
            }.buttonStyle(.borderless)
          }
          if loading { ProgressView().accessibilityLabel("Loading saved views") }
          Button("Refresh views") { Task { await refresh() } }.disabled(loading)
        } header: {
          Text("\(context?.table ?? "Workspace") views")
        } footer: {
          Text(
            "Views keep a table's search, filters, sorting and layout. They are shared through your workspace."
          )
        }
        Section("Default for this table") {
          if let preferred = model.viewDefault {
            Text(preferred.view?.name ?? "Catalog default")
              .accessibilityIdentifier("default-view-name")
            if let reason = preferred.unavailable {
              Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Button("Use current view by default") { setDefault(model.appliedView) }
              .disabled(
                model.defaultWriteability?.writable != true || model.appliedView == nil
                  || model.viewModified
              )
              .accessibilityIdentifier("set-default-view")
            Button("Use catalog default") { setDefault(nil) }
              .disabled(model.defaultWriteability?.writable != true || preferred.viewId == nil)
              .accessibilityIdentifier("clear-default-view")
          }
        }
        Section("View for related records") {
          if let preferred = model.relatedViewDefault {
            Text(preferred.view?.name ?? "All live links")
              .accessibilityIdentifier("related-view-name")
            if let reason = preferred.unavailable {
              Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Button("Use current view for related records") {
              setDefault(model.appliedView, related: true)
            }
            .disabled(
              model.relatedDefaultWriteability?.writable != true || model.appliedView == nil
                || model.viewModified
            )
            .accessibilityIdentifier("set-related-view")
            Button("Use all live related records") { setDefault(nil, related: true) }
              .disabled(
                model.relatedDefaultWriteability?.writable != true || preferred.viewId == nil
              )
              .accessibilityIdentifier("clear-related-view")
          }
        }
        if let unavailable = model.savedViewsUnavailable {
          Section { Text(unavailable).foregroundStyle(.secondary) }
        } else if writable {
          Section {
            TextField("Name", text: $name).accessibilityIdentifier("saved-view-name")
              .focused($editingName)
            Button("Save as new view") { save(update: false) }
              .accessibilityIdentifier("save-view-copy")
            if model.appliedView != nil {
              Button("Update view") { save(update: true) }
                .accessibilityIdentifier("update-saved-view")
              if model.viewModified { Text("View settings have changed.").font(.caption) }
            }
          } header: {
            Text("Save current view")
          }
        } else if let reason = model.savedViewEditingUnavailable {
          Section { Text(reason).foregroundStyle(.secondary) }
        }
        if let action = model.undoAction {
          Section {
            Button {
              undo(action)
            } label: {
              Label("Undo last saved change", systemImage: "arrow.uturn.backward")
            }.accessibilityIdentifier("undo-saved-view")
          }
        }
        if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        if let notice {
          Section { Text(notice).accessibilityIdentifier("saved-view-receipt") }
        }
        if model.savingView { ProgressView().accessibilityLabel("Saving view") }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("saved-views-form")
      .disabled(model.savingView || model.undoing || !current)
      .navigationTitle("Saved views")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(model.savingView || model.undoing)
        }
      }
      .interactiveDismissDisabled(model.savingView || model.undoing)
      .savedUndoShortcut(
        enabled: current && !loading && !editingName && deleting == nil
          && !model.savingView && !model.undoing && model.undoAction != nil
      ) {
        if let action = model.undoAction { undo(action) }
      }
      .task { await refresh() }
      .onDisappear { model.scheduleViewSave() }
      .onChange(of: name) { notice = nil }
      .onChange(of: model.workspaceGeneration) { dismiss() }
      .onChange(of: model.table) { dismiss() }
      .confirmationDialog(
        "Delete this view?",
        isPresented: Binding(
          get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible
      ) {
        if let saved = deleting {
          Button("Delete view", role: .destructive) {
            Task {
              do {
                let deletingApplied = model.appliedView?.byteExactID == saved.byteExactID
                try await model.deleteSavedView(saved, context: context)
                guard current else { return }
                if deletingApplied { name = "" }
                error = nil
                notice = "View deleted."
              } catch { if current { self.error = error.localizedDescription } }
            }
          }
        }
      } message: {
        Text("The view will be removed. Its records will be kept.")
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, idealWidth: 560, minHeight: 480, idealHeight: 620)
    #endif
  }

  private func undo(_ action: CoreUndoAction) {
    notice = nil
    Task {
      do {
        try await model.undo(action, context: context)
        guard current else { return }
        error = nil
        notice = "Saved change undone."
      } catch { if current { self.error = error.localizedDescription } }
    }
  }

  private func setDefault(_ saved: CoreSavedViewRecord?, related: Bool = false) {
    Task {
      do {
        try await model.setDefaultView(saved, context: context, related: related)
        if current {
          error = nil
          notice =
            related
            ? "Related-record view saved."
            : "Default view saved. It applies when opening this table."
        }
      } catch { if current { self.error = error.localizedDescription } }
    }
  }

  private func choose(_ saved: CoreSavedViewRecord?) {
    do {
      try model.applySavedView(saved, context: context)
      if let context { onChoose(NativeDestination(table: context.table, viewID: saved?.id)) }
      dismiss()
    } catch { self.error = error.localizedDescription }
  }

  private func refresh() async {
    loading = true
    defer { loading = false }
    do {
      try await model.refreshSavedViews(context: context)
      if current { error = nil }
    } catch { if current { self.error = error.localizedDescription } }
  }

  private func save(update: Bool) {
    notice = nil
    Task {
      do {
        try await model.saveCurrentView(name: name, update: update, context: context)
        guard current else { return }
        error = nil
        notice = "Saved on this device."
      } catch { if current { self.error = error.localizedDescription } }
    }
  }
}
