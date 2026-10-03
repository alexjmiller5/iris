import Foundation
import Observation

@Observable @MainActor
final class NativeChoiceModel {
  private(set) var options: [String] = []
  private(set) var error: String?
  private(set) var loading = false
  private let load: () async throws -> [String]
  private let isCurrent: () -> Bool
  private var generation = 0

  init(load: @escaping () async throws -> [String], isCurrent: @escaping () -> Bool = { true }) {
    self.load = load
    self.isCurrent = isCurrent
  }

  func refresh() async {
    guard isCurrent(), !Task.isCancelled else { return }
    generation += 1
    let request = generation
    loading = true
    error = nil
    defer { if request == generation { loading = false } }

    func canPublish() -> Bool {
      request == generation && isCurrent() && !Task.isCancelled
    }
    do {
      let loaded = try await load()
      guard canPublish() else { return }
      options = loaded
    } catch {
      guard canPublish(), !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }

  func cancel() {
    generation += 1
    loading = false
  }
}
