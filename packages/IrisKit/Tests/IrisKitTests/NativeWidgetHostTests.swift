import Foundation
import IrisExtensionSupport
import Testing

@testable import IrisKit

@MainActor struct NativeWidgetHostTests {
  @Test func replacingTheDatabaseFileRevokesItsPreviouslyPublishedSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("local.sqlite")
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let model = WorkspaceModel(
      localURL: { file }, credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
    await model.open()
    try model.prepareWidgets()
    let settings = try #require(model.widgets)
    #expect(
      await settings.setSelections(
        [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    await model.close()
    try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("previous.sqlite"))
    let replacement = try await NativeWorkspace(path: file.path)
    try await replacement.createSample()
    try await replacement.close()
    await model.open()
    #expect(model.error == nil)
    #expect(try library.sources().isEmpty)
    await model.close()
  }

  @Test func hostRestoresSourcesAfterCloseAndForgetRevokesTheirPublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("local.sqlite")
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let model = WorkspaceModel(
      localURL: { file }, credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
    await model.open()
    #expect(model.error == nil)
    #expect(model.widgets == nil)
    try model.prepareWidgets()
    let settings = try #require(model.widgets)
    #expect(
      await settings.setSelections(
        [NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    #expect(try library.sources().count == 2)
    await model.close()
    #expect(try library.sources().count == 2)
    await model.open()
    #expect(model.widgets?.selections.map(\.table) == ["notes"])
    try await model.forgetConnection()
    #expect(try library.sources().isEmpty)
    #expect(model.widgets?.selections.isEmpty == true)
    await model.close()
  }

  @Test func sampleWorkspaceCannotPublishOrCreatePersistentWidgetPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      credentialStore: MemoryHubCredentials(nil), widgetLibrary: library)
    await model.open(demo: true)
    #expect(throws: WorkspaceError.self) { try model.prepareWidgets() }
    #expect(try library.sources().isEmpty)
    await model.close()
  }

  @Test func aSavedWorkspaceWithoutAWidgetLibraryStillOffersDueTimeAlerts() async throws {
    // The Mac has no widget extension: integrations need only a saved workspace.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      credentialStore: MemoryHubCredentials(nil), widgetLibrary: nil)
    await model.open()
    #expect(model.canPrepareIntegrations && model.integrations == nil)
    #expect(throws: WorkspaceError.self) { try model.prepareWidgets() }
    try model.prepareIntegrations()
    #expect(model.integrations != nil && model.widgets == nil)
    await model.close()
    // The identity persists: reopening configures the alerts without another prompt.
    await model.open()
    #expect(model.integrations != nil)
    await model.close()
    let demo = WorkspaceModel(
      localURL: { root.appendingPathComponent("demo.sqlite") },
      credentialStore: MemoryHubCredentials(nil), widgetLibrary: nil)
    await demo.open(demo: true)
    #expect(!demo.canPrepareIntegrations)
    await demo.close()
  }
}
