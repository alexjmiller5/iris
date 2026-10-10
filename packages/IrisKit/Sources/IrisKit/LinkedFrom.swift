import Observation
import SwiftUI

/// One record's backlinks from Markdown mentions; ordering and the index live in core.
@Observable @MainActor
final class LinkedFromModel {
  private(set) var rows: [CoreMentionedByRow] = []
  private(set) var nextOffset: CoreCount?
  private(set) var incomplete = false
  /// The search index step is still catching up, so recent mentions may be missing.
  private(set) var indexing = false
  private(set) var loading = false
  private(set) var loaded = false
  private(set) var error: String?
  private let table: String
  private let rowID: String
  private let readPage: (CoreMentionedByArgs) async throws -> CoreMentionedByPage
  private let isCurrent: () -> Bool
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private(set) var isDisposed = false

  init(
    table: String, rowID: String,
    readPage: @escaping (CoreMentionedByArgs) async throws -> CoreMentionedByPage,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.table = table
    self.rowID = rowID
    self.readPage = readPage
    self.isCurrent = isCurrent
  }

  /// The first page by default; `more` appends the next page and keeps rows on failure.
  func load(more: Bool = false) async {
    guard !isDisposed, isCurrent(), !more || (!loading && nextOffset != nil) else { return }
    generation += 1
    let version = generation
    let offset = more ? nextOffset ?? 0 : 0
    loading = true
    error = nil
    defer { if version == generation { loading = false } }
    do {
      let page = try await readPage(
        CoreMentionedByArgs(table: table, rowId: rowID, limit: 20, offset: offset))
      guard version == generation, !isDisposed, isCurrent(), !Task.isCancelled else { return }
      var seen = Set<Data>()
      // Record IDs are opaque bytes; Swift String equality could merge distinct IDs.
      rows = ((more ? rows : []) + page.rows).filter {
        seen.insert(Data(($0.table + "\u{0}" + $0.id).utf8)).inserted
      }
      nextOffset = page.nextOffset
      incomplete = page.incomplete
      indexing = page.indexing
      loaded = true
    } catch {
      if version == generation, !isDisposed { self.error = error.localizedDescription }
    }
  }

  func dispose() {
    isDisposed = true
    generation += 1
  }
}

struct LinkedFromView: View {
  let makeModel: @MainActor () -> LinkedFromModel?
  let canOpen: Bool
  let onOpenRecord: (String, String) -> Void
  @State private var model: LinkedFromModel?

  var body: some View {
    Section {
      if let model {
        if model.incomplete {
          Text("Some records may be missing on this device.").foregroundStyle(.secondary)
        }
        ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
          Button {
            onOpenRecord(row.table, row.id)
          } label: {
            Label {
              VStack(alignment: .leading) {
                Text(row.label)
                Text(row.table.replacingOccurrences(of: "_", with: " "))
                  .font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "arrow.up.forward")
            }
          }
          .accessibilityLabel("Open \(row.label)")
          .disabled(!canOpen)
        }
        if model.loading {
          ProgressView("Loading links")
        } else if let error = model.error {
          Text(error).foregroundStyle(.red)
          Button("Retry links") { Task { await model.load(more: !model.rows.isEmpty) } }
        } else if model.loaded && model.rows.isEmpty {
          Text(
            model.indexing
              ? "No links found yet. Search is still indexing this device."
              : "No stored records mention this record."
          ).foregroundStyle(.secondary)
        } else if model.nextOffset != nil {
          Button("Load more links") { Task { await model.load(more: true) } }
        }
      } else {
        ProgressView("Loading links")
      }
    } header: {
      if model?.indexing == true {
        Text("Linked from (indexing)").accessibilityIdentifier("linked-from-indexing")
      } else {
        Text("Linked from")
      }
    } footer: {
      Text("Records stored on this device whose text mentions this record.")
    }
    .task {
      guard model?.isDisposed != false, let next = makeModel() else { return }
      model = next
      await next.load()
    }
    .onDisappear { model?.dispose() }
  }
}

#Preview("Linked from while indexing") {
  Form {
    LinkedFromView(
      makeModel: {
        LinkedFromModel(table: "topics", rowID: "t") { _ in
          CoreMentionedByPage(rows: [], nextOffset: nil, incomplete: false, indexing: true)
        }
      }, canOpen: true, onOpenRecord: { _, _ in })
  }
}
