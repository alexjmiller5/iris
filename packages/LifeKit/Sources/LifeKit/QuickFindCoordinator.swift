import Foundation
import Observation

@Observable @MainActor
final class QuickFindCoordinator: Identifiable {
  struct Entry: Identifiable {
    let id: NativeDestination
    let label: String
    let excerpt: String
    let unavailable: String?
  }

  let id = UUID()
  let search: QuickFindModel
  let metadata: NativePaletteModel
  var query = "" {
    didSet {
      guard oldValue != query else { return }
      search.query = query
      metadata.query = query
      invalidateActivation()
      reconcileSelection()
    }
  }
  private(set) var selection: NativeDestination?
  private(set) var opening: NativeDestination?
  private(set) var error: String?
  private var active = true
  private var revision = 0
  private let resolve:
    @MainActor (NativeDestination, () -> Bool) async throws -> NativeResolvedDestination
  private let current: () -> Bool

  init(
    search: QuickFindModel, metadata: NativePaletteModel,
    resolve:
      @escaping @MainActor (NativeDestination, () -> Bool) async throws -> NativeResolvedDestination,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.search = search
    self.metadata = metadata
    self.resolve = resolve
    current = isCurrent
  }

  var isCurrent: Bool { active && current() }

  var entries: [Entry] {
    guard isCurrent else { return [] }
    return metadata.filteredEntries.map {
      Entry(id: $0.destination, label: $0.label, excerpt: "", unavailable: $0.unavailable)
    }
      + search.results.map {
        Entry(
          id: NativeDestination(table: $0.table, rowID: $0.id), label: $0.label,
          excerpt: $0.excerpt, unavailable: nil)
      }
  }

  var enabledIDs: [NativeDestination] {
    entries.filter { $0.unavailable == nil }.map(\.id)
  }

  func loadMetadata() async {
    guard isCurrent else { return }
    await metadata.load()
    reconcileSelection()
  }

  func refreshMetadata() async {
    guard isCurrent else { return }
    await metadata.refresh()
    reconcileSelection()
  }

  func reloadSearch(more: Bool = false) async {
    guard isCurrent else { return }
    if !more { error = nil }
    await search.reload(more: more)
    reconcileSelection()
  }

  func reconcileSelection() {
    let enabled = enabledIDs
    if let selection, enabled.contains(selection) { return }
    selection = enabled.first
  }

  func moveSelection(_ direction: Int) {
    let enabled = enabledIDs
    guard opening == nil, !enabled.isEmpty else { return }
    if let selection, let index = enabled.firstIndex(of: selection) {
      self.selection = enabled[(index + direction + enabled.count) % enabled.count]
    } else {
      selection = direction < 0 ? enabled.last : enabled.first
    }
  }

  func activateSelection(commit: (NativeResolvedDestination) throws -> Void) async {
    reconcileSelection()
    guard let selection else { return }
    await activate(selection, commit: commit)
  }

  func activate(
    _ destination: NativeDestination, commit: (NativeResolvedDestination) throws -> Void
  ) async {
    guard isCurrent, !Task.isCancelled, enabledIDs.contains(destination) else { return }
    revision += 1
    let request = revision
    selection = destination
    opening = destination
    error = nil
    defer { if request == revision { opening = nil } }
    func canCommit() -> Bool { isCurrent && request == revision && !Task.isCancelled }
    do {
      let resolved = try await resolve(destination, canCommit)
      guard canCommit() else { return }
      try commit(resolved)
    } catch {
      guard canCommit(), !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }

  private func invalidateActivation() {
    revision += 1
    opening = nil
    error = nil
  }

  func cancel() {
    active = false
    invalidateActivation()
    selection = nil
    search.cancel()
    metadata.dispose()
  }
}
