import Foundation
import Observation

struct NativeRecentEntry: Identifiable {
  let destination: NativeDestination
  var label: String
  var isTrashed = false
  var loading = true
  var unavailable: String?
  var id: NativeDestination { destination }
}

@Observable @MainActor
final class NativeRecentsModel {
  private(set) var destinations: [NativeDestination] = []
  private(set) var entries: [NativeRecentEntry] = []
  private(set) var storageError: String?
  private let store: NativeRecentsStore?
  private let resolve: (NativeDestination) async throws -> NativeResolvedDestination
  private let isCurrent: () -> Bool
  private var revision = 0
  private var active = true

  init(
    store: NativeRecentsStore? = nil,
    resolve: @escaping (NativeDestination) async throws -> NativeResolvedDestination,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.store = store
    self.resolve = resolve
    self.isCurrent = isCurrent
    do { destinations = try store?.load() ?? [] } catch { storageFailed(error) }
  }

  private var current: Bool { active && isCurrent() && !Task.isCancelled }

  func refresh() async {
    guard current else { return }
    revision += 1
    let request = revision
    let requested = destinations
    entries = requested.map {
      NativeRecentEntry(destination: $0, label: $0.rowID ?? $0.viewID ?? $0.table)
    }
    for (index, destination) in requested.enumerated() {
      guard current, request == revision else { return }
      do {
        let resolved = try await resolve(destination)
        guard current, request == revision else { return }
        entries[index] = NativeRecentEntry(
          destination: destination, label: resolved.label, isTrashed: resolved.isTrashed,
          loading: false)
      } catch is CancellationError {
        return
      } catch {
        guard current, request == revision else { return }
        entries[index].loading = false
        entries[index].unavailable = error.localizedDescription
      }
    }
  }

  /// The host calls this only after its guarded navigation commits to the UI.
  func navigationSucceeded(_ destination: NativeDestination) async {
    guard current else { return }
    change { [destination] + $0 }
    await refresh()
  }

  func remove(_ destination: NativeDestination) async {
    guard current else { return }
    change { $0.filter { $0 != destination } }
    await refresh()
  }

  func cancel() {
    active = false
    revision += 1
    entries = []
  }

  private func change(_ change: ([NativeDestination]) -> [NativeDestination]) {
    destinations = NativeRecentsStore.bounded(change(destinations))
    guard let store, storageError == nil else { return }
    do { destinations = try store.update(change) } catch { storageFailed(error) }
  }

  private func storageFailed(_ error: Error) {
    storageError = error.localizedDescription
      + " New recents remain available until this workspace closes."
  }
}
