import Foundation
import LifeExtensionSupport
import LifeWidgets
import Testing

@testable import LifeKit

@MainActor struct WidgetEntryTests {
  @Test func configuredTimelinesReadIndependentSourcesAndRefuseRevokedChoices() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let library = WidgetLibrary(root: root.appendingPathComponent("shared"))
    let settings = NativeWidgetSettings(
      workspace: workspace, library: library, workspaceID: "workspace", replicaID: "replica",
      preferencesURL: root.appendingPathComponent("widgets.json"))
    #expect(await settings.setSelections([
      NativeWidgetSelection(table: "notes", viewID: nil),
      NativeWidgetSelection(table: "topics", viewID: nil),
    ], partial: true))
    let sources = try library.sources().filter { $0.kind == .list }
    #expect(sources.count == 2)
    let now = Date()
    for source in sources {
      let list = WidgetEntry.timeline(sourceID: source.id, library: library, now: now)
      #expect(list.entries.first?.result.state == .current)
      #expect(list.entries.first?.result.content?.title == source.title)
      #expect(list.entries.first?.result.content?.partial == true)
      let count = WidgetEntry.timeline(sourceID: source.id, kind: .count, library: library, now: now)
      #expect(count.entries.first?.result.state == .current)
      #expect(count.entries.first?.result.content?.rows.first?["count"] != nil)
      let today = WidgetEntry.timeline(sourceID: source.id, calendarOnly: true, library: library, now: now)
      #expect(today.entries.first?.result.state == .unavailable)
    }
    let missing = WidgetEntry.timeline(sourceID: "missing", library: library, now: now)
    #expect(missing.entries.first?.result.state == .unavailable)
    try settings.revoke()
    for source in sources {
      let removed = WidgetEntry.timeline(sourceID: source.id, library: library, now: now)
      #expect(removed.entries.first?.result.state == .unavailable)
      #expect(removed.entries.first?.result.content == nil)
    }
    try await workspace.close()
  }

  @Test func dailyConfigurationSchedulesBoundaryWithHostClosed() async throws {
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
    #expect(await settings.setSelections([
      NativeWidgetSelection(table: "notes", viewID: view.id),
    ], partial: false))
    try await workspace.close()
    let id = WidgetLibrary.sourceID(workspaceID: "workspace", table: "notes", viewID: view.id, kind: .list)
    let timeline = WidgetEntry.timeline(sourceID: id, calendarOnly: true, library: library)
    #expect(timeline.entries.count == 2)
    #expect(timeline.entries.first?.result.state == .current)
    #expect(timeline.entries.last?.date == timeline.entries.first?.result.content?.nextBoundary)
    #expect(timeline.entries.first?.result.content?.effectiveDay != timeline.entries.last?.result.content?.effectiveDay)
  }
}
