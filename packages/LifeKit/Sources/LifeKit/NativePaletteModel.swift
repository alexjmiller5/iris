import Foundation
import Observation

@Observable @MainActor
final class NativePaletteModel {
  struct Entry: Identifiable {
    let destination: NativeDestination
    let label: String
    let unavailable: String?
    var id: [Data?] { destination.identity }
  }

  var query = ""
  private(set) var entries: [Entry] = []
  private(set) var loading = false
  private(set) var error: String?
  private var attempted = false
  private var active = true
  private var generation = 0
  private let catalog: () async throws -> WorkspaceCatalog
  private let listViews: (String) async throws -> CoreSavedViewList
  private let current: () -> Bool

  convenience init(workspace: NativeWorkspace, isCurrent: @escaping () -> Bool = { true }) {
    self.init(catalog: workspace.catalog, listViews: workspace.listViews, isCurrent: isCurrent)
  }

  init(catalog: @escaping () async throws -> WorkspaceCatalog,
    listViews: @escaping (String) async throws -> CoreSavedViewList,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.catalog = catalog
    self.listViews = listViews
    current = isCurrent
  }

  var isCurrent: Bool { active && current() }

  var filteredEntries: [Entry] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return entries.filter { "\($0.label) \($0.destination.table)".lowercased().contains(text) || text.isEmpty }
  }

  func load() async {
    guard !attempted else { return }
    await refresh()
  }

  func refresh() async {
    guard isCurrent, !Task.isCancelled else { return }
    generation += 1
    let request = generation
    attempted = true
    loading = true
    entries = []
    error = nil
    defer { if request == generation { loading = false } }

    func canPublish() -> Bool { isCurrent && request == generation && !Task.isCancelled }
    func report(_ message: String) {
      error = error.map { $0 + "\n" + message } ?? message
    }
    do {
      let catalog = try await catalog()
      guard canPublish() else { return }
      let tables = catalog.tables.compactMap { $0["id"]?.text }
      entries = tables.map { Entry(destination: NativeDestination(table: $0), label: $0, unavailable: nil) }
      // Sequential requests expose progress and let record searches use the core
      // between metadata reads. Typing never restarts this discovery.
      for table in tables {
        do {
          let listed = try await listViews(table)
          guard canPublish() else { return }
          if let reason = listed.unavailable { report(table + ": " + reason) }
          entries += listed.views.map { view in
            let available = view.tbl == table && view.deletedAt == nil
              && view.definition != nil && view.view != nil
            return Entry(destination: NativeDestination(table: table, viewID: view.id), label: view.name,
              unavailable: view.unavailable ?? (available ? nil : "This view is unavailable."))
          }
        } catch {
          guard canPublish(), !(error is CancellationError) else { return }
          report(table + ": " + error.localizedDescription)
        }
      }
    } catch {
      guard canPublish(), !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }

  func dispose() {
    active = false
    generation += 1
    loading = false
    entries = []
    error = nil
  }
}
