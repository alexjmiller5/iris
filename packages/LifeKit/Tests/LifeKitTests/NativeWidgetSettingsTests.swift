import Foundation
import LifeExtensionSupport
import Testing

@testable import LifeKit

@MainActor struct NativeWidgetSettingsTests {
  @Test func publicationAndRevocationNotifyWidgetTimelines() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    var changes = 0
    let settings = NativeWidgetSettings(
      workspace: workspace, library: WidgetLibrary(root: root.appendingPathComponent("shared")),
      workspaceID: "workspace", replicaID: "replica", preferencesURL: root.appendingPathComponent("widgets.json"),
      didChange: { changes += 1 })
    #expect(await settings.setSelections([NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    #expect(changes == 1)
    try settings.revoke()
    #expect(changes == 2)
    try await workspace.close()
  }

  @Test func explicitResetPreservesUnreadSettingsAndAllowsANewSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let preferences = root.appendingPathComponent("widgets.json")
    let damaged = Data("unreadable settings".utf8)
    try damaged.write(to: preferences)
    let settings = NativeWidgetSettings(
      workspace: workspace, library: WidgetLibrary(root: root.appendingPathComponent("shared")),
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(settings.unreadable)
    try settings.resetUnreadSettings()
    #expect(!settings.unreadable)
    let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("widgets.json.unread-") }
    #expect(retained.count == 1)
    #expect(try Data(contentsOf: #require(retained.first)) == damaged)
    #expect(await settings.setSelections([NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    try await workspace.close()
  }

  @Test func enabledSourcesPersistAndCanBeReadAfterHostCloses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let preferences = root.appendingPathComponent("preferences/widgets.json")
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(
      await settings.setSelections(
        [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    #expect(settings.error == nil)
    #expect(try library.sources().count == 2)
    let restored = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(restored.selections.map(\.table) == ["notes"])
    settings.cancel()
    restored.cancel()
    try await workspace.close()
    let source = try #require(try library.sources().first { $0.kind == .list })
    #expect(
      library.store(workspaceID: source.workspaceID).read(
        sourceID: source.id,
        workspaceID: source.workspaceID, replicaID: source.replicaID
      ).state == .current)
  }

  @Test func restoredPreferencesCannotRestoreRevokedAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let preferences = root.appendingPathComponent("preferences/widgets.json")
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(
      await settings.setSelections(
        [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    let saved = try Data(contentsOf: preferences)
    try settings.revoke()
    // An old preferences file restored from backup must not restore authority.
    try saved.write(to: preferences, options: .atomic)
    let reopened = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(reopened.selections.isEmpty)
    await reopened.refresh(partial: false)
    #expect(try library.sources().isEmpty)
    try await workspace.close()
  }

  @Test func publicationFailureKeepsPreviousRowsExplicitlyStaleAndUnreadPreferencesUntouched()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let preferences = root.appendingPathComponent("preferences/widgets.json")
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(
      await settings.setSelections(
        [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    #expect(
      !(await settings.setSelections(
        [
          NativeWidgetSelection(table: "notes", viewID: nil),
          NativeWidgetSelection(table: "missing", viewID: nil),
        ], partial: false)))
    let source = try #require(try library.sources().first { $0.kind == .list })
    #expect(
      library.store(workspaceID: source.workspaceID).read(
        sourceID: source.id,
        workspaceID: source.workspaceID, replicaID: source.replicaID
      ).state == .stale)
    try Data("unreadable".utf8).write(to: preferences)
    let unread = NativeWidgetSettings(
      workspace: workspace, library: library,
      workspaceID: "workspace", replicaID: "replica", preferencesURL: preferences)
    #expect(!(await unread.setSelections([], partial: false)))
    #expect(try Data(contentsOf: preferences) == Data("unreadable".utf8))
    try await workspace.close()
  }
}
