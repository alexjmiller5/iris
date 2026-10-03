import Foundation
import Observation

extension CoreSearchHit {
  var identity: [Data] { [Data(table.utf8), Data(id.utf8)] }
}

@Observable @MainActor
final class QuickFindModel: Identifiable {
  let id = UUID()
  var query = "" {
    didSet { if oldValue != query { invalidate(clear: true) } }
  }
  private(set) var results: [CoreSearchHit] = []
  private(set) var loading = false
  private(set) var opening: [Data]?
  private(set) var error: String?
  private(set) var canLoadMore = false
  private var offset = 0
  private var revision = 0
  private var openRevision = 0
  private var active = true
  private let search: (CoreSearchArgs) async throws -> [CoreSearchHit]
  private let read: (CoreView) async throws -> [WorkspaceRow]
  private let current: () -> Bool

  init(
    search: @escaping (CoreSearchArgs) async throws -> [CoreSearchHit],
    read: @escaping (CoreView) async throws -> [WorkspaceRow],
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.search = search
    self.read = read
    current = isCurrent
  }

  var isCurrent: Bool { active && current() }

  private func invalidate(clear: Bool) {
    revision += 1
    openRevision += 1
    loading = false
    opening = nil
    error = nil
    if clear {
      results = []
      offset = 0
      canLoadMore = false
    }
  }

  func cancel() {
    active = false
    invalidate(clear: true)
  }

  func reload(more: Bool = false) async {
    guard isCurrent, !Task.isCancelled else { return }
    if more && (loading || !canLoadMore) { return }
    if !more { invalidate(clear: true) }
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    revision += 1
    let request = revision
    let start = more ? offset : 0
    loading = true
    error = nil
    do {
      let page = try await search(CoreSearchArgs(text: text, limit: 50, offset: start))
      guard isCurrent, request == revision, !Task.isCancelled else { return }
      var seen = Set(results.map(\.identity))
      results += page.filter { seen.insert($0.identity).inserted }
      offset = start + page.count
      canLoadMore = page.count == 50
    } catch {
      guard isCurrent, request == revision, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
    loading = false
  }

  func open(_ hit: CoreSearchHit) async -> WorkspaceRow? {
    guard isCurrent, results.contains(where: { $0.identity == hit.identity }) else { return nil }
    openRevision += 1
    let request = openRevision
    let searchRequest = revision
    opening = hit.identity
    error = nil
    do {
      let rows = try await read(
        CoreView(
          table: hit.table,
          filters: [CoreFilter(column: "id", op: .eq, value: .string(hit.id))], limit: 1))
      guard isCurrent, request == openRevision, searchRequest == revision, !Task.isCancelled else {
        return nil
      }
      opening = nil
      guard let row = rows.first(where: { $0.byteExactID == Data(hit.id.utf8) }) else {
        error = "This record is no longer available locally. Search again to refresh the results."
        return nil
      }
      return row
    } catch {
      guard isCurrent, request == openRevision, searchRequest == revision, !Task.isCancelled else {
        return nil
      }
      opening = nil
      self.error = error.localizedDescription
      return nil
    }
  }
}
