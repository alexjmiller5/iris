import Foundation
import Testing

@testable import IrisKit

@MainActor
struct TableNavigationUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_TABLE_NAV_SIMULATOR"] != nil))
    func prepareLargeSystemTable() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["IRIS_TEST_TABLE_NAV_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let runtime = try IrisCoreRuntime()
      let workspace = try NativeWorkspace(path: WorkspaceModel.localURL().path, runtime: runtime)
      runtime.context.evaluateScript(
        #"""
        IrisSql.run("CREATE TABLE IF NOT EXISTS provenance (id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, tbl TEXT, row_id TEXT, col TEXT, source TEXT)");
        IrisSql.run("INSERT OR REPLACE INTO catalog_tables(id,kind,display,purpose) VALUES ('provenance','system','source','Synthetic provenance navigation fixture')");
        IrisSql.run("INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('provenance.source','provenance','source','Source',0,'text')");
        IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50000) INSERT OR IGNORE INTO provenance(id,created_at,updated_at,tbl,row_id,col,source) SELECT 'trace-'||i,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z','notes','synthetic-'||i,'title','Synthetic source '||i FROM n");
        """#)
      try #require(runtime.context.exception == nil)
      let catalog = try await workspace.catalog()
      #expect(
        catalog.tables.first { $0["id"] == .string("provenance") }?["readOnly"] == .bool(true))
      #expect(
        try await workspace.rows(view: CoreView(table: "provenance", limit: 100)).count == 100)
      try await workspace.close()
      if let endpoint = env["IRIS_TEST_TABLE_NAV_HUB"] {
        let local = try WorkspaceModel.localURL()
        let replica = WorkspaceModel.replicaURL(
          root: local.deletingLastPathComponent(), endpoint: endpoint)
        try FileManager.default.createDirectory(
          at: replica.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Start every run from the seeded copy; durable rejections must not leak between runs.
        for suffix in ["", "-wal", "-shm"] {
          try? FileManager.default.removeItem(atPath: replica.path + suffix)
        }
        try FileManager.default.copyItem(at: local, to: replica)
        try HubCredentialStore().save(
          HubCredentials(endpoint: endpoint, token: "synthetic-navigation-fixture"))
      }
    }
  #endif
}
