import Foundation
import Testing

@testable import IrisKit

@MainActor
struct SearchTableSettingsTests {
  private func eventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !(try await condition()) {
      try #require(ContinuousClock.now < deadline, "The search index loop did not apply the choice")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test func turningATableOffAndBackOnGoesThroughTheIndexLoop() async throws {
    let model = WorkspaceModel(widgetLibrary: nil)
    await model.open(demo: true)
    let workspace = try #require(model.client)
    let notes = try #require(
      try await workspace.searchTables().tables.first { $0.table == "notes" })
    #expect(notes.indexed && notes.defaultExclusion == nil && notes.override == nil)
    #expect(notes.rows > 0 && notes.textBytes > 0)
    let title = try #require(try await workspace.rows(table: "notes").first?.label)
    let word = try #require(title.split(separator: " ").first.map(String.init))
    let hits = { try await workspace.search(CoreSearchArgs(text: word, table: "notes")) }
    #expect(!(try await hits().isEmpty))

    let off = try await model.setSearchTable(notes, indexed: false, on: workspace)
    let excluded = try #require(off.tables.first { $0.table == "notes" })
    #expect(!excluded.indexed && excluded.override == false)
    // The model schedules the index step itself; it removes the table from results.
    try await eventually { try await hits().isEmpty }
    try await eventually { model.searchIndexing == 0 }

    // Matching the default again clears the choice instead of storing it.
    let on = try await model.setSearchTable(excluded, indexed: true, on: workspace)
    #expect(on.tables.first { $0.table == "notes" }?.override == nil)
    try await eventually { !(try await hits().isEmpty) }
  }

  @Test func detailsNameRecordsTextAndWhyADefaultIsOff() {
    let table = CoreSearchTable(
      table: "history", indexed: false, defaultExclusion: .size, override: nil, rows: 420_000,
      textBytes: 31_200_000)
    #expect(
      SearchTableText.detail(table, sizeLimit: 50_000)
        == "420,000 records · about 31.2 MB of text · Off by default: over 50,000 records")
    var provenance = table
    provenance.defaultExclusion = .provenance
    provenance.rows = 1
    provenance.textBytes = 12
    #expect(
      SearchTableText.detail(provenance, sizeLimit: 50_000)
        == "1 record · about 12 bytes of text · Off by default: provenance links")
    #expect(SearchTableText.choice(table, indexed: true) == true)
    #expect(SearchTableText.choice(table, indexed: false) == nil)
    var included = table
    included.defaultExclusion = nil
    #expect(SearchTableText.choice(included, indexed: false) == false)
    #expect(SearchTableText.choice(included, indexed: true) == nil)
  }
}
