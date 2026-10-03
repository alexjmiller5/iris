import SwiftUI

struct QuickFindView: View {
  @Bindable var model: QuickFindModel
  let incomplete: Bool
  let onOpen: (CoreSearchHit, WorkspaceRow) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Search all tables", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .submitLabel(.search)
            .accessibilityIdentifier("quick-find-query")
            .onSubmit { focused = false }
          Text("Search only records stored on this device.")
            .font(.caption).foregroundStyle(.secondary)
          if incomplete {
            Text("Some hub tables were skipped during sync and may be incomplete here.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.padding()
        if let error = model.error {
          HStack(alignment: .top) {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
            Spacer()
            Button("Search again") { Task { await searchAgain() } }
              .disabled(model.loading || model.opening != nil)
          }.font(.callout).padding(.horizontal).padding(.bottom)
        }
        List {
          if model.results.isEmpty && !model.loading && model.error == nil {
            ContentUnavailableView(
              model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Find a record" : "No matches",
              systemImage: "magnifyingglass",
              description: Text("Search by a title or words in a record."))
          }
          ForEach(model.results, id: \.identity) { hit in
            Button {
              Task {
                if let row = await model.open(hit) { onOpen(hit, row) }
              }
            } label: {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(hit.label).font(.headline).foregroundStyle(.primary).lineLimit(2)
                  Text(hit.table).font(.caption).foregroundStyle(.secondary)
                  if !hit.excerpt.isEmpty {
                    Text(hit.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                  }
                }
                Spacer()
                if model.opening == hit.identity { ProgressView() }
              }
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.opening != nil)
            .accessibilityIdentifier("quick-find-result-\(hit.table)-\(hit.id)")
          }
        }
        .scrollDismissesKeyboard(.interactively)
        HStack {
          Text(model.results.count == 1 ? "1 result" : "\(model.results.count) results")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if model.loading { ProgressView().accessibilityLabel("Searching") }
          if model.canLoadMore {
            Button("Load more") { Task { await model.reload(more: true) } }
              .disabled(model.loading || model.opening != nil)
              .accessibilityIdentifier("quick-find-more")
          }
        }.padding().background(.bar)
      }
      .navigationTitle("Find records")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.cancel()
            dismiss()
          }.keyboardShortcut(.cancelAction)
        }
      }
      .task { focused = true }
      .task(id: model.query) {
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        await model.reload()
      }
      .onDisappear { model.cancel() }
    }
    #if os(macOS)
      .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 620)
    #endif
  }

  func searchAgain() async {
    await model.reload()
  }
}
