import Foundation
import Observation

/// A recent destination and its display snapshot. Identity is only the destination;
/// the label, trash mark and reason are a display cache that paints at launch and is
/// refreshed from local data afterwards, never used to navigate.
struct NativeRecentEntry: Identifiable, Equatable, Codable {
  let destination: NativeDestination
  var label: String
  var isTrashed = false
  var loading = true
  var unavailable: String?
  var id: NativeDestination { destination }

  init(
    destination: NativeDestination, label: String, isTrashed: Bool = false, loading: Bool = true,
    unavailable: String? = nil
  ) {
    self.destination = destination
    self.label = label
    self.isTrashed = isTrashed
    self.loading = loading
    self.unavailable = unavailable
  }

  /// A destination never resolved on this device shows its raw identity until it is.
  init(pending destination: NativeDestination) {
    self.init(destination: destination, label: destination.rowID ?? destination.viewID ?? destination.table)
  }

  private enum CodingKeys: String, CodingKey { case label, trashed, unavailable }

  init(from decoder: Decoder) throws {
    let destination = try NativeDestination(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let label = try container.decodeIfPresent(String.self, forKey: .label) else {
      self.init(pending: destination)
      return
    }
    self.init(
      destination: destination, label: label,
      isTrashed: try container.decode(Bool.self, forKey: .trashed), loading: false,
      unavailable: try container.decodeIfPresent(String.self, forKey: .unavailable))
  }

  /// The destination's own keys, plus the snapshot once it has been resolved.
  func encode(to encoder: Encoder) throws {
    try destination.encode(to: encoder)
    guard !loading else { return }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(label, forKey: .label)
    try container.encode(isTrashed, forKey: .trashed)
    try container.encode(unavailable, forKey: .unavailable)
  }
}

@Observable @MainActor
final class NativeRecentsModel {
  private(set) var entries: [NativeRecentEntry] = []
  private(set) var storageError: String?
  private let store: NativeRecentsStore?
  private let resolve: (NativeDestination) async throws -> NativeResolvedDestination
  private let isCurrent: () -> Bool
  private var revision = 0
  private var active = true

  var destinations: [NativeDestination] { entries.map(\.destination) }

  init(
    store: NativeRecentsStore? = nil,
    resolve: @escaping (NativeDestination) async throws -> NativeResolvedDestination,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.store = store
    self.resolve = resolve
    self.isCurrent = isCurrent
    // Stored snapshots paint with the sidebar; refresh corrects them afterwards.
    do { entries = try store?.load() ?? [] } catch { storageFailed(error) }
  }

  private var current: Bool { active && isCurrent() && !Task.isCancelled }

  /// Re-resolves the shown entries in order, updating only those that changed.
  func refresh() async {
    guard current else { return }
    revision += 1
    let request = revision
    var changed = false
    for entry in entries {
      guard current, request == revision else { return }
      var next = entry
      do {
        let resolved = try await resolve(entry.destination)
        next = NativeRecentEntry(
          destination: entry.destination, label: resolved.label, isTrashed: resolved.isTrashed,
          loading: false)
      } catch is CancellationError {
        return
      } catch {
        next.loading = false
        next.unavailable = error.localizedDescription
      }
      guard current, request == revision else { return }
      guard next != entry, let index = entries.firstIndex(where: { $0.destination == entry.destination })
      else { continue }
      entries[index] = next
      changed = true
    }
    guard changed else { return }
    let shown = entries
    _ = persist { stored in
      stored.map { saved in shown.first { $0.destination == saved.destination && !$0.loading } ?? saved }
    }
  }

  /// The host calls this only after its guarded navigation commits to the UI, with
  /// the label it shows for the destination at that moment.
  func navigationSucceeded(
    _ destination: NativeDestination, label: String? = nil, isTrashed: Bool = false
  ) async {
    guard current else { return }
    let entry =
      label.map {
        NativeRecentEntry(destination: destination, label: $0, isTrashed: isTrashed, loading: false)
      } ?? entries.first { $0.destination == destination } ?? NativeRecentEntry(pending: destination)
    change { [entry] + $0 }
    await refresh()
  }

  func remove(_ destination: NativeDestination) async {
    guard current else { return }
    change { $0.filter { $0.destination != destination } }
    await refresh()
  }

  func cancel() {
    active = false
    revision += 1
    entries = []
  }

  private func change(_ change: ([NativeRecentEntry]) -> [NativeRecentEntry]) {
    entries = NativeRecentsStore.bounded(change(entries))
    if let stored = persist(change) { entries = stored }
  }

  private func persist(_ change: ([NativeRecentEntry]) -> [NativeRecentEntry]) -> [NativeRecentEntry]? {
    guard let store, storageError == nil else { return nil }
    do { return try store.update(change) } catch {
      storageFailed(error)
      return nil
    }
  }

  private func storageFailed(_ error: Error) {
    storageError = error.localizedDescription
      + " New recents remain available until this workspace closes."
  }
}
