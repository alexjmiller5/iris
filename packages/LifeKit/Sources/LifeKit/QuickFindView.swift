import SwiftUI

struct QuickFindView: View {
  @Bindable var model: QuickFindCoordinator
  let incomplete: Bool
  let onOpen: (NativeResolvedDestination) throws -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        QuickFindQuery(model: model, incomplete: incomplete, onOpen: onOpen)
        if let error = model.metadata.error {
          QuickFindMessage(
            message: error, retryTitle: "Retry destinations",
            disabled: model.metadata.loading || model.opening != nil,
            retry: { Task { await model.refreshMetadata() } }
          )
          .accessibilityIdentifier("quick-find-metadata-error")
        }
        if let error = model.error ?? model.search.error {
          QuickFindMessage(
            message: error, retryTitle: "Search again",
            disabled: model.search.loading || model.opening != nil,
            retry: { Task { await searchAgain() } }
          )
          .accessibilityIdentifier("quick-find-error")
        }
        QuickFindResults(model: model, onOpen: onOpen)
        QuickFindFooter(
          count: model.entries.count,
          searching: model.search.loading, discovering: model.metadata.loading,
          opening: model.opening != nil, canLoadMore: model.search.canLoadMore,
          loadMore: { Task { await model.reloadSearch(more: true) } })
      }
      .navigationTitle("Quick Find")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.cancel()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("quick-find-cancel")
        }
      }
      .task { await model.loadMetadata() }
      .task(id: model.query) {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        await model.reloadSearch()
      }
      .onDisappear { model.cancel() }
    }
    #if os(macOS)
      .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 620)
    #endif
  }

  func searchAgain() async {
    await model.reloadSearch()
  }
}

private struct QuickFindQuery: View {
  @Bindable var model: QuickFindCoordinator
  let incomplete: Bool
  let onOpen: (NativeResolvedDestination) throws -> Void
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Find tables, views, and records", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .submitLabel(.go)
        .accessibilityIdentifier("quick-find-query")
        .onSubmit {
          Task {
            guard model.opening == nil else { return }
            await model.activateSelection(commit: onOpen)
          }
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
          guard press.modifiers.isEmpty else { return .ignored }
          model.moveSelection(press.key == .upArrow ? -1 : 1)
          return .handled
        }
      Text("Search only records stored on this device.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if incomplete {
        Text("Some hub tables were skipped during sync and may be incomplete here.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding()
    .task { focused = true }
  }
}

private struct QuickFindResults: View {
  @Bindable var model: QuickFindCoordinator
  let onOpen: (NativeResolvedDestination) throws -> Void

  var body: some View {
    ScrollViewReader { scroll in
      List {
        if model.entries.isEmpty && !model.search.loading && !model.metadata.loading
          && model.error == nil && model.search.error == nil && model.metadata.error == nil
        {
          ContentUnavailableView(
            "No matches", systemImage: "magnifyingglass",
            description: Text("Find a table, saved view, or words in a record."))
        }
        ForEach(model.entries) { entry in
          Button {
            Task { await model.activate(entry.id, commit: onOpen) }
          } label: {
            QuickFindEntryRow(
              entry: entry, opening: model.opening == entry.id, selected: model.selection == entry.id)
          }
          .buttonStyle(.plain)
          .disabled(entry.unavailable != nil || model.opening != nil)
          .listRowBackground(
            model.selection == entry.id ? Color.accentColor.opacity(0.15) : Color.clear
          )
          .accessibilityAddTraits(model.selection == entry.id ? .isSelected : [])
          .accessibilityIdentifier(accessibilityID(entry.id))
          .id(entry.id)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: model.enabledIDs, initial: true) { model.reconcileSelection() }
      .onChange(of: model.selection) {
        if let selected = model.selection { scroll.scrollTo(selected) }
      }
    }
  }

  private func accessibilityID(_ destination: NativeDestination) -> String {
    if let row = destination.rowID { return "quick-find-result-\(destination.table)-\(row)" }
    if let view = destination.viewID { return "quick-find-view-\(destination.table)-\(view)" }
    return "quick-find-table-\(destination.table)"
  }
}

private struct QuickFindEntryRow: View {
  let entry: QuickFindCoordinator.Entry
  let opening: Bool
  /// Secondary text loses contrast on the tinted selection, so it turns primary there.
  let selected: Bool

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.label).font(.headline).foregroundStyle(.primary).lineLimit(2)
        HStack(spacing: 4) {
          if entry.id.rowID != nil {
            Text("Record")
          } else if entry.id.viewID != nil {
            Text("Saved view")
          } else {
            Text("Table")
          }
          if entry.id.rowID != nil || entry.id.viewID != nil { Text(entry.id.table) }
          if let status = entry.status {
            Text(status.value)
              .padding(.horizontal, 6)
              .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
              .help(status.help ?? status.value)
              .accessibilityLabel("Status \(status.value)")
              .accessibilityHint(status.help ?? "")
              .accessibilityIdentifier("quick-find-status")
          }
        }.font(.caption).foregroundStyle(selected ? .primary : .secondary)
        if !entry.excerpt.isEmpty {
          Text(entry.excerpt).font(.callout).foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(3)
        }
        if let reason = entry.unavailable {
          Text(reason).font(.callout).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if opening { ProgressView() }
    }
    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
  }
}

private struct QuickFindMessage: View {
  let message: String
  let retryTitle: LocalizedStringKey
  let disabled: Bool
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Text(message).foregroundStyle(.red).textSelection(.enabled)
      Spacer()
      Button(retryTitle, action: retry).disabled(disabled)
    }.font(.callout).padding(.horizontal).padding(.bottom)
  }
}

private struct QuickFindFooter: View {
  let count: Int
  let searching: Bool
  let discovering: Bool
  let opening: Bool
  let canLoadMore: Bool
  let loadMore: () -> Void

  var body: some View {
    HStack {
      Text(count == 1 ? "1 result" : "\(count) results")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      if searching || discovering {
        ProgressView().accessibilityLabel(searching ? "Searching" : "Loading destinations")
      }
      if canLoadMore {
        Button("Load more", action: loadMore)
          .disabled(searching || opening)
          .accessibilityIdentifier("quick-find-more")
      }
    }.padding().background(.bar)
  }
}
