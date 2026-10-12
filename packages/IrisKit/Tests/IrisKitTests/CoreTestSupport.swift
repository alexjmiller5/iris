import JavaScriptCore

@testable import IrisKit

extension NativeWorkspace {
  /// Runs the search index step to completion, as WorkspaceModel does after changes.
  func indexSearch() async throws {
    while !(try await searchIndexStep(budgetMs: 60_000)).done {}
  }
}

/// Waits up to `timeout` for `condition`, which a request on the core thread makes true.
/// Counting main-actor yields does not bound work on another thread.
@MainActor func waitForCore(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
}

extension IrisCoreRuntime {
  /// A runtime created on the core thread, as NativeWorkspace(path:) creates its own:
  /// JavaScriptCore runs its heap timers on the creating thread's run loop.
  static func onCore() async throws -> IrisCoreRuntime {
    try await Task { @IrisCoreActor in try IrisCoreRuntime() }.value
  }

  /// Runs trusted test script on the core executor, where NativeWorkspace runs requests.
  /// Script that reaches Swift (IrisSql, a held request, __irisFinish) must run here: the
  /// bridge is IrisCoreActor-isolated. Reading plain JS globals works from any actor.
  @IrisCoreActor func evaluateOnCore(_ script: String) {
    context.evaluateScript(script)
  }

  /// The same, returning what `read` takes from the result.
  @IrisCoreActor func evaluateOnCore<T: Sendable>(
    _ script: String, _ read: @Sendable (JSValue?) -> T
  ) -> T {
    read(context.evaluateScript(script))
  }

  /// The same without waiting (cleanup, `defer`). It is queued on the core executor at
  /// once, so it runs before any core request submitted after it.
  func evaluateOnCoreSoon(_ script: String) {
    Task { @IrisCoreActor in _ = self.context.evaluateScript(script) }
  }
}
