import Foundation
import Observation

extension CoreSearchHit {
  var identity: [Data] { [Data(table.utf8), Data(id.utf8)] }
}

/// A hit's lifecycle status and its catalog option description.
struct QuickFindStatus: Equatable {
  let value: String
  let help: String?
}

@Observable @MainActor
final class QuickFindModel: Identifiable {
  let id = UUID()
  var query = "" {
    didSet { if oldValue != query { invalidate(clear: true) } }
  }
  private(set) var results: [CoreSearchHit] = []
  private var statuses: [[Data]: QuickFindStatus] = [:]
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
  /// Each table's lifecycle field: the select named `status` (life-data's estate
  /// status dictionary). Its value labels the hit; its option description explains it.
  private let statusFields: [String: CatalogField]

  init(
    search: @escaping (CoreSearchArgs) async throws -> [CoreSearchHit],
    read: @escaping (CoreView) async throws -> [WorkspaceRow],
    isCurrent: @escaping () -> Bool = { true },
    statusFields: [String: CatalogField] = [:]
  ) {
    self.search = search
    self.read = read
    current = isCurrent
    self.statusFields = statusFields
  }

  func status(of hit: CoreSearchHit) -> QuickFindStatus? { statuses[hit.identity] }

  var isCurrent: Bool { active && current() }

  private func invalidate(clear: Bool) {
    revision += 1
    openRevision += 1
    loading = false
    opening = nil
    error = nil
    if clear {
      results = []
      statuses = [:]
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
      let fresh = page.filter { seen.insert($0.identity).inserted }
      results += fresh
      offset = start + page.count
      canLoadMore = page.count == 50
      loading = false
      // A failed status read leaves the hit unlabeled; it never fails the search.
      for hit in fresh {
        guard let field = statusFields[hit.table],
          let rows = try? await read(
            CoreView(
              table: hit.table,
              filters: [CoreFilter(column: "id", op: .eq, value: .string(hit.id))], limit: 1))
        else { continue }
        guard isCurrent, request == revision, !Task.isCancelled else { return }
        if let value = rows.first(where: { $0.byteExactID == Data(hit.id.utf8) })?
          .record[field.id]?.text.nonempty
        {
          statuses[hit.identity] = QuickFindStatus(value: value, help: field.optionHelp(value))
        }
      }
      return
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
