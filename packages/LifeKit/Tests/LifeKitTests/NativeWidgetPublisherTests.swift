import Foundation
import LifeExtensionSupport
import Testing

@testable import LifeKit

@MainActor struct NativeWidgetPublisherTests {
  @Test func publishesActualCanonicalListAndCountAfterHostCloses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: root.appendingPathComponent("live.sqlite").path)
    try await workspace.createSample()
    let store = WidgetPublicationStore(root: root.appendingPathComponent("widgets"))
    let publisher = NativeWidgetPublisher(workspace: workspace, store: store)
    let requests: [NativeWidgetSourceRequest] = [CoreReadPlanKind.list, .count].map { kind in
      NativeWidgetSourceRequest(
        id: kind.rawValue, title: "Synthetic source",
        plan: CorePrepareReadPlanArgs(
          workspaceID: "workspace", replicaID: "replica", table: "notes", kind: kind))
    }
    try await publisher.publish(requests, partial: true)
    try await workspace.close()
    let list = store.read(sourceID: "list", workspaceID: "workspace", replicaID: "replica")
    let count = store.read(sourceID: "count", workspaceID: "workspace", replicaID: "replica")
    #expect(list.state == .current)
    #expect(list.content?.partial == true)
    #expect(list.content?.rows.isEmpty == false)
    #expect(count.state == .current)
    #expect(count.content?.rows.first?["count"] == .number(Double(list.content!.rows.count)))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("widgets"), includingPropertiesForKeys: nil
      )
      .allSatisfy { !$0.lastPathComponent.hasPrefix(".capture-") })
  }

  @Test func canceledPreparationNeverPublishesOrLeavesSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let store = WidgetPublicationStore(root: root)
    let publisher = NativeWidgetPublisher(workspace: workspace, store: store)
    let work = Task { @MainActor in
      try await publisher.publish(
        [
          NativeWidgetSourceRequest(
            id: "source", title: "Synthetic source",
            plan: CorePrepareReadPlanArgs(
              workspaceID: "workspace", replicaID: "replica",
              table: "notes", kind: .list))
        ], partial: false)
    }
    work.cancel()
    await #expect(throws: (any Error).self) { try await work.value }
    #expect(
      store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
        == .unavailable)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try await workspace.close()
  }

  @Test func revocationDuringPlanPreparationCannotRestoreAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let store = WidgetPublicationStore(root: root)
    let publisher = NativeWidgetPublisher(
      prepare: { args in
        let plan = try await workspace.prepareReadPlan(args)
        try store.revoke()
        return plan
      }, snapshot: workspace.exportWidgetSnapshot, store: store)
    await #expect(throws: (any Error).self) {
      try await publisher.publish(
        [
          NativeWidgetSourceRequest(
            id: "source", title: "Synthetic source",
            plan: CorePrepareReadPlanArgs(
              workspaceID: "workspace", replicaID: "replica",
              table: "notes", kind: .list))
        ], partial: false)
    }
    #expect(
      store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
        == .unavailable)
    try await workspace.close()
  }
}
