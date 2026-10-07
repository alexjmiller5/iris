import Foundation

struct NativeWidgetSourceRequest: Sendable {
  let id: String
  let title: String
  let plan: CorePrepareReadPlanArgs
}

/// Host-only preparation. The extension never links the writer or JS runtime.
@MainActor struct NativeWidgetPublisher {
  private let prepare: (CorePrepareReadPlanArgs) async throws -> CoreReadPlan
  private let snapshot: (URL) async throws -> Void
  private let store: WidgetPublicationStore

  init(workspace: NativeWorkspace, store: WidgetPublicationStore) {
    self.init(
      prepare: workspace.prepareReadPlan, snapshot: workspace.exportWidgetSnapshot, store: store)
  }

  init(
    prepare: @escaping (CorePrepareReadPlanArgs) async throws -> CoreReadPlan,
    snapshot: @escaping (URL) async throws -> Void, store: WidgetPublicationStore
  ) {
    self.prepare = prepare
    self.snapshot = snapshot
    self.store = store
  }

  func publish(_ requests: [NativeWidgetSourceRequest], partial: Bool) async throws {
    try Task.checkCancellation()
    guard let first = requests.first, requests.count <= 64,
      requests.allSatisfy({
        $0.plan.workspaceID.utf8.elementsEqual(first.plan.workspaceID.utf8)
          && $0.plan.replicaID.utf8.elementsEqual(first.plan.replicaID.utf8)
      })
    else {
      throw WorkspaceError(message: "Choose widget sources from one workspace.", violations: [])
    }
    // Revocation during preparation or the queue wait invalidates this entire
    // request, not just the final disk copy. A new explicit refresh may retry.
    let permit = try store.beginPublication()
    var sources: [WidgetSource] = []
    for request in requests {
      try Task.checkCancellation()
      let plan = try await prepare(request.plan)
      try Task.checkCancellation()
      sources.append(WidgetSource(id: request.id, title: request.title, plan: plan))
    }
    let capturedAt = Date()
    let file = store.root.appendingPathComponent(".capture-" + UUID().uuidString + ".sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: file.path + suffix)
      }
    }
    try await snapshot(file)
    try Task.checkCancellation()
    let prepared = sources
    let store = store
    let work = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      try store.publish(
        workspaceID: first.plan.workspaceID, replicaID: first.plan.replicaID,
        dataAsOf: capturedAt, partial: partial, sources: prepared, permit: permit
      ) { destination in
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: file, to: destination)
        try Task.checkCancellation()
      }
    }
    try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
  }
}
