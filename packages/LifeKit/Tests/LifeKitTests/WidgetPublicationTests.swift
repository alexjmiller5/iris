import Foundation
import LifeExtensionSupport
import SQLite3
import Testing

struct WidgetPublicationTests {
  private func fixture(_ body: (WidgetPublicationStore, URL, [WidgetSource]) throws -> Void) throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("input.sqlite")
    var handle: OpaquePointer?
    #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
    #expect(
      sqlite3_exec(
        handle,
        "CREATE TABLE items(id TEXT PRIMARY KEY,name TEXT); INSERT INTO items VALUES ('one','Synthetic title')",
        nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let value: [String: Any] = [
      "version": 1, "workspaceID": "workspace", "replicaID": "replica", "table": "items",
      "viewID": NSNull(), "viewUpdatedAt": NSNull(), "kind": "list",
      "sql": "SELECT id,name FROM items LIMIT 20", "parameters": [], "columns": ["id", "name"],
      "displayColumn": "name", "maximumRows": 20, "calendarPolicy": NSNull(),
      "guards": [
        [
          "kind": "schema",
          "sql": "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
          "parameters": [], "expectedRows": [["name": "items"]],
        ],
        [
          "kind": "catalog", "sql": "SELECT 'fixture' AS identity", "parameters": [],
          "expectedRows": [["identity": "fixture"]],
        ],
      ],
    ]
    let plan = try JSONDecoder().decode(
      CoreReadPlan.self, from: JSONSerialization.data(withJSONObject: value))
    try body(
      WidgetPublicationStore(root: directory.appendingPathComponent("widgets")), database,
      [WidgetSource(id: "source", title: "Synthetic table", plan: plan)])
  }

  @Test func publicationIsCoherentAndFailedReplacementRetainsPreviousResult() throws {
    try fixture { store, database, sources in
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(timeIntervalSince1970: 100),
        partial: true, sources: sources
      ) {
        try FileManager.default.copyItem(at: database, to: $0)
      }
      let first = store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica")
      #expect(first.state == .current)
      #expect(first.content?.rows.first?["name"] == .string("Synthetic title"))
      #expect(first.content?.partial == true)
      #expect(throws: (any Error).self) {
        try store.publish(
          workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
          sources: sources
        ) { _ in throw CocoaError(.fileWriteUnknown) }
      }
      let after = store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica")
      #expect(after.content?.dataAsOf == first.content?.dataAsOf)
      #expect(after.state == .current)
    }
  }

  @Test func mismatchedDatabaseRetainsExplicitlyStaleFallbackAndRevokeRemovesIt() throws {
    try fixture { store, database, sources in
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: sources
      ) {
        try FileManager.default.copyItem(at: database, to: $0)
      }
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .current)
      try store.withCurrentPublication { _, snapshot in
        var handle: OpaquePointer?
        #expect(sqlite3_open(snapshot.path, &handle) == SQLITE_OK)
        #expect(
          sqlite3_exec(handle, "UPDATE items SET name='wrong generation rows'", nil, nil, nil)
            == SQLITE_OK)
        sqlite3_close(handle)
      }
      let stale = store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica")
      #expect(stale.state == .stale)
      #expect(stale.content?.rows.first?["name"] == .string("Synthetic title"))
      #expect(
        store.read(sourceID: "source", workspaceID: "other", replicaID: "replica").state
          == .unavailable)
      try store.revoke()
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .unavailable)
    }
  }

  @Test func heldReaderPreventsGenerationReclamationAndNewPublicationCanRetry() throws {
    try fixture { store, database, sources in
      let copy: (URL) throws -> Void = { try FileManager.default.copyItem(at: database, to: $0) }
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: sources, copyDatabase: copy)
      var old: URL?
      try store.withCurrentPublication { _, snapshot in
        old = snapshot
        #expect(throws: (any Error).self) {
          try store.publish(
            workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
            sources: sources, copyDatabase: copy)
        }
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
      }
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: sources, copyDatabase: copy)
      #expect(!FileManager.default.fileExists(atPath: try #require(old).path))
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .current)
    }
  }

  @Test func removalOfSourceAndInvalidPublicationNeverShowOldTitles() throws {
    try fixture { store, database, sources in
      let copy: (URL) throws -> Void = { try FileManager.default.copyItem(at: database, to: $0) }
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: sources, copyDatabase: copy)
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .current)
      #expect(throws: (any Error).self) {
        try store.publish(
          workspaceID: "different", replicaID: "replica", dataAsOf: Date(), partial: false,
          sources: sources, copyDatabase: copy)
      }
      try store.publish(
        workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
        sources: [], copyDatabase: copy)
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .unavailable)
      #expect(
        try FileManager.default.contentsOfDirectory(
          at: store.root.appendingPathComponent("fallback"), includingPropertiesForKeys: nil
        ).isEmpty)
    }
  }

  @Test func revocationDuringSnapshotPreparationCannotRepublishOldAccess() throws {
    try fixture { store, database, sources in
      #expect(throws: (any Error).self) {
        try store.publish(
          workspaceID: "workspace", replicaID: "replica", dataAsOf: Date(), partial: false,
          sources: sources
        ) { output in
          try FileManager.default.copyItem(at: database, to: output)
          try store.revoke()
        }
      }
      #expect(
        store.read(sourceID: "source", workspaceID: "workspace", replicaID: "replica").state
          == .unavailable)
    }
  }

  @Test func pickerSourcesStayBoundToWorkspaceAndDisappearAfterRevocation() throws {
    try fixture { base, database, sources in
      let library = WidgetLibrary(root: base.root)
      for workspaceID in ["workspace", "other-workspace"] {
        var plan = sources[0].plan
        plan.workspaceID = workspaceID
        let source = WidgetSource(
          id: WidgetLibrary.sourceID(
            workspaceID: workspaceID,
            table: plan.table, viewID: nil, kind: .list), title: "Synthetic table", plan: plan)
        try library.store(workspaceID: workspaceID).publish(
          workspaceID: workspaceID,
          replicaID: "replica", dataAsOf: Date(), partial: false, sources: [source]
        ) {
          try FileManager.default.copyItem(at: database, to: $0)
        }
      }
      let choices = try library.sources()
      #expect(choices.count == 2)
      #expect(Set(choices.map(\.id)).count == 2)
      #expect(choices.allSatisfy { $0.table == "items" && $0.title == "Synthetic table" })
      try library.store(workspaceID: "other-workspace").revoke()
      #expect(try library.sources().map(\.workspaceID) == ["workspace"])
      #expect(
        WidgetLibrary.sourceID(workspaceID: "workspace", table: "café", viewID: nil, kind: .list)
          != WidgetLibrary.sourceID(
            workspaceID: "workspace", table: "cafe\u{301}", viewID: nil, kind: .list))
      #expect(
        WidgetLibrary.sourceID(workspaceID: "workspace", table: "items", viewID: nil, kind: .list)
          != WidgetLibrary.sourceID(
            workspaceID: "workspace", table: "items", viewID: nil, kind: .count))
    }
  }
}
