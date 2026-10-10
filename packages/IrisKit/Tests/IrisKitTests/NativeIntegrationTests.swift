import Foundation
import IrisExtensionSupport
import Testing

@testable import IrisKit

@MainActor final class RecordingSpotlightIndex: SpotlightIndexing {
  var domains: [String: [SpotlightItem]] = [:]
  func replace(domain: String, items: [SpotlightItem]) async throws { domains[domain] = items }
  func remove(domains removed: [String]) async throws {
    domains = domains.filter { key, _ in
      !removed.contains { key == $0 || key.hasPrefix($0 + ".") }
    }
  }
}

@MainActor struct NativeIntegrationTests {
  private func fixture(
    _ body: (NativeWorkspace, URL, RecordingSpotlightIndex, NativeWorkspaceBinding) async throws
      -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    do {
      try await body(
        workspace, root.appendingPathComponent("integrations.json"), RecordingSpotlightIndex(),
        .local(UUID()))
    } catch {
      try? await workspace.close()
      throw error
    }
    try await workspace.close()
  }

  private func settings(
    _ workspace: NativeWorkspace, _ url: URL, _ index: RecordingSpotlightIndex,
    _ binding: NativeWorkspaceBinding
  ) -> NativeIntegrationSettings {
    NativeIntegrationSettings(
      workspace: workspace, workspaceID: "local:workspace", binding: binding,
      preferencesURL: url, spotlight: index)
  }

  @Test func spotlightIndexesTitlesOfEnabledTablesOnlyAndOpensRows() async throws {
    try await fixture { workspace, url, index, binding in
      let model = settings(workspace, url, index, binding)
      #expect(await model.setSpotlightTables(["notes"]))
      let rows = try await workspace.rows(table: "notes")
      let items = try #require(index.domains[model.spotlightDomain(table: "notes")])
      #expect(index.domains.count == 1)
      #expect(Set(items.map(\.title)) == Set(rows.compactMap { $0.record["title"]?.text }))
      #expect(!rows.isEmpty && items.count == rows.count)
      for item in items {
        let destination = try NativeDeepLink(url: #require(URL(string: item.id)))
          .destination(matching: binding)
        #expect(destination.table == "notes")
        #expect(rows.contains { $0.record["id"]?.text == destination.rowID })
        // Titles only: body text never becomes part of the indexed identity or title.
        let body = rows.first { $0.record["id"]?.text == destination.rowID }?.record["body"]?.text
        if let body, !body.isEmpty { #expect(!item.id.contains(body) && item.title != body) }
      }
      let reopened = settings(workspace, url, index, binding)
      #expect(reopened.spotlightTables == ["notes"])
      #expect(await model.setSpotlightTables([]))
      #expect(index.domains.isEmpty)
    }
  }

  @Test func spotlightRefreshDropsDeletedRowsAndRemoveAllClearsTheWorkspace() async throws {
    try await fixture { workspace, url, index, binding in
      let model = settings(workspace, url, index, binding)
      #expect(await model.setSpotlightTables(["notes", "topics"]))
      #expect(index.domains.count == 2)
      let row = try #require(try await workspace.rows(table: "notes").first)
      let deleted = row.record["id"]!.text
      _ = try await workspace.write(
        table: "notes",
        patch: ["id": .string(deleted), "deleted_at": .bool(true)],
        expectedUpdatedAt: row.record["updated_at"]?.text)
      await model.refreshSpotlight()
      #expect(index.domains[model.spotlightDomain(table: "notes")]?.contains { $0.id.contains(deleted) } == false)
      try await model.removeAll()
      #expect(index.domains.isEmpty)
      #expect(model.spotlightTables.isEmpty)
    }
  }

  @Test func lookupSearchesOnlyTheConfiguredTablesDisplayTitles() async throws {
    try await fixture { workspace, url, index, binding in
      try await workspace.indexSearch()
      let model = settings(workspace, url, index, binding)
      let title = try #require(try await workspace.rows(table: "notes").first?.record["title"]?.text)
      let word = try #require(title.split(separator: " ").first.map(String.init))
      await #expect(throws: WorkspaceError.self) { try await model.lookUp(word) }
      #expect(model.setLookupTable("notes"))
      let hits = try await model.lookUp(word)
      #expect(!hits.isEmpty)
      #expect(hits.allSatisfy { $0.title.localizedStandardContains(word) })
      #expect(hits.allSatisfy { (try? NativeDeepLink(url: $0.url).destination(matching: binding).table) == "notes" })
      #expect(settings(workspace, url, index, binding).lookupTable == "notes")
      #expect(model.setLookupTable(nil))
      await #expect(throws: WorkspaceError.self) { try await model.lookUp(word) }
    }
  }

  @Test func dailySourceIsDurableAndUnreadablePreferencesAreKept() async throws {
    try await fixture { workspace, url, index, binding in
      let model = settings(workspace, url, index, binding)
      let daily = NativeWidgetSelection(table: "notes", viewID: "view-1")
      #expect(model.setDailySource(daily))
      #expect(settings(workspace, url, index, binding).dailySource?.id == daily.id)
      try Data("not json".utf8).write(to: url)
      let damaged = settings(workspace, url, index, binding)
      #expect(damaged.dailySource == nil)
      #expect(damaged.error != nil)
      #expect(damaged.setDailySource(daily))
      let kept = try FileManager.default.contentsOfDirectory(
        at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      #expect(kept.contains { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".unread-") })
    }
  }
}
