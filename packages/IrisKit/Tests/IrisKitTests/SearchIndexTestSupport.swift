@testable import IrisKit

extension NativeWorkspace {
  /// Runs the search index step to completion, as WorkspaceModel does after changes.
  func indexSearch() async throws {
    while !(try await searchIndexStep(budgetMs: 60_000)).done {}
  }
}
