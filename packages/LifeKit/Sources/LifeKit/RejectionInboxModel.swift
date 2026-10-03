import Foundation
import Observation

extension CoreRejectedEdit {
  struct InboxID: Hashable {
    let table: Data
    let rowID: Data
  }
  // Preserve the original strings on the wire; Swift String equality folds Unicode.
  var inboxID: InboxID { InboxID(table: Data(table.utf8), rowID: Data(rowID.utf8)) }
}

/// Presentation state only: the shared core validates and reads the durable inbox.
/// Owners refresh after database changes and dispose when their workspace closes.
@Observable @MainActor
final class RejectionInboxModel {
  private(set) var total: Int?
  private(set) var entries: [CoreRejectedEdit] = []
  private(set) var nextOffset: Int? = 0
  private(set) var loading = false
  private(set) var error: String?
  private let readStatus: () async throws -> CoreSyncStatus
  private let readPage: (CoreRejectionsArgs) async throws -> CoreRejectionsPage
  private let isCurrent: () -> Bool
  private var generation = 0
  private var disposed = false

  init(
    readStatus: @escaping () async throws -> CoreSyncStatus,
    readPage: @escaping (CoreRejectionsArgs) async throws -> CoreRejectionsPage,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.readStatus = readStatus
    self.readPage = readPage
    self.isCurrent = isCurrent
  }

  private func current(_ version: Int) -> Bool {
    !disposed && version == generation && isCurrent() && !Task.isCancelled
  }

  func refresh() async {
    guard current(generation) else { return }
    generation += 1
    let version = generation
    total = nil
    entries = []
    nextOffset = 0
    loading = true
    error = nil
    defer { if version == generation { loading = false } }
    do {
      let status = try await readStatus()
      guard current(version) else { return }
      total = status.rejected
      try await appendPage(offset: 0, version: version)
    } catch {
      guard current(version) else { return }
      self.error = error.localizedDescription
    }
  }

  func loadMore() async {
    guard current(generation), !loading, total != nil, let offset = nextOffset else { return }
    let version = generation
    loading = true
    error = nil
    defer { if version == generation { loading = false } }
    do {
      try await appendPage(offset: offset, version: version)
    } catch {
      guard current(version) else { return }
      self.error = error.localizedDescription
    }
  }

  private func appendPage(offset: Int, version: Int) async throws {
    let page = try await readPage(CoreRejectionsArgs(limit: 100, offset: offset))
    guard current(version) else { return }
    var positions = Dictionary(
      uniqueKeysWithValues: entries.enumerated().map { ($0.element.inboxID, $0.offset) })
    for entry in page.rejections {
      if let index = positions[entry.inboxID] {
        entries[index] = entry
      } else {
        positions[entry.inboxID] = entries.count
        entries.append(entry)
      }
    }
    nextOffset = page.nextOffset
  }

  func dispose() {
    disposed = true
    generation += 1
    loading = false
  }
}
