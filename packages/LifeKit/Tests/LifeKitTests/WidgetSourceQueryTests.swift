import Foundation
import LifeExtensionSupport
import LifeWidgets
import Testing

@testable import LifeKit

@MainActor struct WidgetSourceQueryTests {
  @Test func dailyPickerOffersOnlyCalendarBoundSavedViews() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let view = try await workspace.saveView(
      CoreSaveViewArgs(table: "notes", name: "Synthetic daily view",
        definition: CoreSavedViewDefinition(version: 2, columns: ["title"],
          filters: [CoreFilter(column: "updated_at", op: .lte, relative: .today)],
          timeZone: "UTC", dayStartMinutes: 180)))
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library, workspaceID: "workspace", replicaID: "replica",
      preferencesURL: root.appendingPathComponent("widgets.json"))
    let published = await settings.setSelections([
      NativeWidgetSelection(table: "notes", viewID: nil),
      NativeWidgetSelection(table: "notes", viewID: view.id),
    ], partial: false)
    try #require(published, Comment(rawValue: settings.error ?? "No publication error"))
    #expect(try await WidgetSourceQuery(library: library).suggestedEntities().count == 2)
    let daily = try await CalendarWidgetSourceQuery(library: library).suggestedEntities()
    #expect(daily.count == 1)
    #expect(daily.first?.title == "Synthetic daily view")
    let source = try #require(try library.sources().first { $0.id == daily.first?.id })
    #expect(source.usesCalendar)
    #expect(source.viewID == view.id)
    try await workspace.close()
  }

  @Test func configurationResolvesOnlyAuthorizedListSourcesAndDropsRevokedIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library, workspaceID: "workspace", replicaID: "replica",
      preferencesURL: root.appendingPathComponent("widgets.json"))
    #expect(await settings.setSelections([NativeWidgetSelection(table: "notes", viewID: nil)], partial: false))
    let query = WidgetSourceQuery(library: library)
    let suggested = try await query.suggestedEntities()
    #expect(suggested.count == 1)
    let source = try #require(suggested.first)
    #expect(source.title == "notes")
    #expect(try await query.entities(for: [source.id]).map(\.id) == [source.id])
    #expect(try await query.entities(for: ["unknown"]).isEmpty)
    #expect(try await CalendarWidgetSourceQuery(library: library).suggestedEntities().isEmpty)
    try settings.revoke()
    #expect(try await query.suggestedEntities().isEmpty)
    #expect(try await query.entities(for: [source.id]).isEmpty)
    try await workspace.close()
  }
}
