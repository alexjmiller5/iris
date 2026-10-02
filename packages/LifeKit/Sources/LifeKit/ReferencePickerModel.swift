import Foundation
import Observation

@Observable @MainActor
final class ReferencePickerModel {
  let table: String
  private(set) var selection: ReferenceSelection
  private(set) var rows: [WorkspaceRow] = []
  private(set) var loading = false
  private(set) var canLoadMore = false
  private(set) var error: String?
  var search = ""
  private var labels: [String: String] = [:]
  private var revision = 0
  private let load: (CoreView) async throws -> [WorkspaceRow]

  init(
    table: String, value: String, multiple: Bool,
    load: @escaping (CoreView) async throws -> [WorkspaceRow]
  ) throws {
    self.table = table
    selection = try ReferenceSelection(value: value, multiple: multiple)
    self.load = load
  }

  func label(for id: String) -> String { labels[id] ?? "Unavailable" }

  func choose(_ row: WorkspaceRow) {
    labels[row.id] = row.label
    selection.choose(row.id)
  }

  func remove(_ id: String) { selection.remove(id) }

  func resolveSelected() async {
    for id in selection.ids {
      do {
        let result = try await load(
          CoreView(
            table: table, filters: [CoreFilter(column: "id", op: .eq, value: .string(id))], limit: 1
          ))
        guard !Task.isCancelled else { return }
        if let row = result.first(where: { $0.id == id }) { labels[id] = row.label }
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func reload(more: Bool = false) async {
    revision += 1
    let request = revision
    let query = search
    loading = true
    error = nil
    do {
      let result = try await load(
        CoreView(table: table, limit: 100, offset: more ? rows.count : 0, search: query))
      guard request == revision, query == search, !Task.isCancelled else { return }
      rows = more ? rows + result : result
      for row in result { labels[row.id] = row.label }
      canLoadMore = result.count == 100
    } catch {
      guard request == revision, query == search, !Task.isCancelled else { return }
      self.error = error.localizedDescription
      if !more { rows = [] }
    }
    loading = false
  }

  func invalidateSearch() {
    revision += 1
    loading = false
  }
}
