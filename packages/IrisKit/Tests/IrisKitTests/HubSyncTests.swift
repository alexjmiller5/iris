import Foundation
import GRDB
import JavaScriptCore
import Testing

@testable import IrisKit

@Suite(.serialized) @MainActor
struct HubSyncTests {
  @Test func exactOnlineLookupUsesRealSQLiteCollationWithoutTrimmingTheID() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try IrisCoreRuntime()
    let path = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: path, runtime: runtime)
    try await seed.createSample()
    runtime.context.evaluateScript(
      #"""
      const ddl = `CREATE TABLE collated (id TEXT PRIMARY KEY COLLATE NOCASE, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, title TEXT)`;
      IrisSql.run(ddl);
      IrisSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
      IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('collated','table','title')");
      IrisSql.run("INSERT INTO collated VALUES (' Case ID ','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z',NULL,NULL,'Collated fixture')");
      """#)
    #expect(runtime.context.exception == nil)
    try await seed.close()
    try HubFixture.state.load(path: path)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let viewer = try NativeWorkspace(path: ":memory:")
    _ = try await viewer.sync(using: hub, tables: ["collated": false])
    let result = try await viewer.remoteRow(using: hub, table: "collated", id: " case id ")
    #expect(result.row?.id == " Case ID " && result.row?.label == "Collated fixture")
    #expect(try await viewer.remoteRow(using: hub, table: "collated", id: "case id").row == nil)
    #expect(try await viewer.rows(table: "collated").isEmpty)
    try await viewer.close()
  }

  @Test func reopeningPartialReplicaOfflineKeepsItsIncompleteNotice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let seed = try NativeWorkspace(path: directory.appendingPathComponent("hub.sqlite").path)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: directory.appendingPathComponent("hub.sqlite").path)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let credentials = HubCredentials(endpoint: hub.endpoint, token: "fixture-scoped-token")
    func makeModel() -> WorkspaceModel {
      WorkspaceModel(
        localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub },
        credentialStore: MemoryHubCredentials(credentials))
    }
    let first = makeModel()
    try await first.connect(credentials, remember: false)
    first.table = "notes"
    await first.reload()
    let cached = try #require(first.rows.first)
    try first.saveDownloads(
      ReplicaPreferences(tables: ["notes": false]), context: #require(first.downloadContext))
    await first.synchronize()
    #expect(first.partialTableNotice != nil)
    let persistedSkippedTables = first.skippedTables
    #expect(persistedSkippedTables.contains("notes"))
    await first.close()
    HubFixture.state.setStatus(503)
    defer { HubFixture.state.setStatus(200) }
    let reopened = makeModel()
    await reopened.resumeConnection()
    reopened.table = "notes"
    await reopened.reload()
    #expect(reopened.rows.first?.record == cached.record)
    #expect(
      reopened.partialTableNotice != nil,
      "Cached partial records must still disclose incompleteness when reopening offline")
    #expect(
      reopened.skippedTables == persistedSkippedTables,
      "Find and reference warnings must use the same durable status")
    await reopened.close()
  }

  @Test func onlineBrowserCapturesReplicaContextAndRejectsTableRoundTripAndClose() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let seed = try NativeWorkspace(path: directory.appendingPathComponent("hub.sqlite").path)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: directory.appendingPathComponent("hub.sqlite").path)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, makeTransport: { _ in hub })
    #expect(model.makeOnlineBrowser() == nil)
    try await model.connect(
      HubCredentials(endpoint: hub.endpoint, token: "fixture-scoped-token"), remember: false)
    model.table = "notes"
    let online = try #require(model.makeOnlineBrowser())
    await online.reload()
    #expect(online.error == nil)
    #expect(!online.rows.isEmpty)
    await online.open(try #require(online.rows.first))
    #expect(online.selected?.record["title"] != nil)
    model.table = "topics"
    model.table = "notes"
    online.selected = nil
    await online.open(try #require(online.rows.first))
    #expect(
      online.selected == nil, "Leaving and returning to a table must invalidate the old sheet")
    let closed = try #require(model.makeOnlineBrowser())
    await model.close()
    await closed.reload()
    #expect(closed.rows.isEmpty && closed.error == nil)
    #expect(model.makeOnlineBrowser() == nil)
  }

  @Test func downloadChoicesApplyOnNextSyncRetainRowsAndRemainScopedOnReconnect() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let seed = try NativeWorkspace(path: directory.appendingPathComponent("hub.sqlite").path)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: directory.appendingPathComponent("hub.sqlite").path)
    func makeModel() -> WorkspaceModel {
      WorkspaceModel(
        localURL: { directory.appendingPathComponent("local.sqlite") },
        makeTransport: { credentials in
          let configuration = URLSessionConfiguration.ephemeral
          configuration.protocolClasses = [HubFixture.self]
          return try HubTransport(
            endpoint: credentials.endpoint, token: credentials.token, configuration: configuration)
        })
    }
    let credentials = HubCredentials(
      endpoint: "https://fixture.invalid/", token: "fixture-scoped-token")
    let model = makeModel()
    try await model.connect(credentials, remember: false)
    model.table = "notes"
    await model.reload()
    let stored = try #require(model.rows.first?.record)
    let before = model.syncResult
    let context = try #require(model.downloadContext)
    let choices = ReplicaPreferences(maxRows: 0, tables: ["topics": true, "history": false])
    try model.saveDownloads(choices, context: context)
    #expect(model.syncResult == before, "Saving settings must not silently start network work")
    #expect(model.rows.first?.record == stored)
    await model.synchronize()
    #expect(model.syncResult?.skipped.contains("notes") == true)
    #expect(model.syncResult?.skipped.contains("history") == true)
    #expect(model.syncResult?.skipped.contains("topics") == false)
    #expect(model.syncResult?.skipped.contains("catalog_tables") == false)
    #expect(model.rows.first?.record == stored, "A skipped table keeps existing local rows")
    #expect(model.partialTableNotice != nil)
    await model.close()
    #expect(throws: WorkspaceError.self) {
      try model.saveDownloads(ReplicaPreferences(), context: context)
    }
    let recreated = makeModel()
    try await recreated.connect(credentials, remember: false)
    #expect(recreated.downloadPreferences == choices)
    #expect(recreated.syncResult?.skipped.contains("notes") == true)
    recreated.table = "notes"
    await recreated.reload()
    #expect(recreated.rows.first?.record == stored)
    let previousEndpoint = try #require(recreated.downloadContext)
    try await recreated.connect(
      HubCredentials(endpoint: "https://other.invalid", token: "fixture-scoped-token"),
      remember: false)
    #expect(recreated.error == nil)
    #expect(recreated.downloadPreferences == ReplicaPreferences())
    #expect(recreated.syncResult?.skipped.contains("notes") == false)
    #expect(throws: WorkspaceError.self) {
      try recreated.saveDownloads(choices, context: previousEndpoint)
    }
    await recreated.close()
  }

  @Test func compilerDependenciesPermitUnrelatedSkipsButRequireActualHistoryReads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try IrisCoreRuntime()
    let hubPath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: hubPath, runtime: runtime)
    try await seed.createSample()
    runtime.context.evaluateScript(
      #"""
      const ddl = `CREATE TABLE provenance (id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT, detail TEXT)`;
      IrisSql.run(ddl);
      IrisSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
      IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('provenance','table','detail')");
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('provenance.detail','provenance','detail','text')");
      IrisSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['fixture-local','notes','invariant',1,"SELECT id FROM changed WHERE title='Blocked'",'Synthetic rule.']);
      """#)
    #expect(runtime.context.exception == nil)
    try await seed.close()
    try HubFixture.state.load(path: hubPath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let replicaRuntime = try IrisCoreRuntime()
    let replica = try NativeWorkspace(
      path: directory.appendingPathComponent("replica.sqlite").path, runtime: replicaRuntime)
    let partial = try await replica.sync(
      using: hub, tables: ["history": false, "provenance": false])
    #expect(Set(partial.skipped).isSuperset(of: ["history", "provenance"]))
    #expect(try await replica.writeability(table: "notes").writable)
    let row = try #require(try await replica.rows(table: "notes").first)
    await #expect(throws: WorkspaceError.self) {
      try await replica.write(
        table: "notes", patch: ["id": .string(row.id), "title": .string("Blocked")],
        expectedUpdatedAt: row.record["updated_at"]?.text)
    }
    #expect(try await replica.rows(table: "notes").first?.record == row.record)
    #expect(try await replica.status().pendingUiEdits == 0)
    _ = try await replica.write(
      table: "notes", patch: ["id": .string(row.id), "title": .string("Allowed partial")],
      expectedUpdatedAt: row.record["updated_at"]?.text)
    _ = try await replica.sync(using: hub, tables: ["history": false, "provenance": false])
    #expect(try await replica.status().pendingUiEdits == 0)
    #expect(
      HubFixture.state.record(table: "notes", id: row.id)?["title"] == .string("Allowed partial"))
    HubFixture.state.changeRule(
      "fixture-local", sql: "SELECT id FROM changed WHERE (SELECT count(*) FROM history)<0")
    _ = try await replica.sync(using: hub, tables: ["history": false, "provenance": false])
    let blocked = try await replica.writeability(table: "notes")
    #expect(!blocked.writable && blocked.reason?.message.contains("history") == true)
    _ = try await replica.sync(using: hub, tables: ["history": true, "provenance": false])
    #expect(try await replica.writeability(table: "notes").writable)
    // Older hosts keep the conservative global gate when the optional capability is absent.
    replicaRuntime.context.evaluateScript("delete IrisSql.readDependencies")
    #expect(!((try await replica.writeability(table: "notes")).writable))
    try await replica.close()
  }

  @Test func editingAdvisoryTracksFullSyncMissingHistoryAndInterruptedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try IrisCoreRuntime()
    let hubPath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: hubPath, runtime: runtime)
    try await seed.createSample()
    runtime.context.evaluateScript(
      """
      IrisSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['fixture-title','notes','invariant',1,"SELECT id FROM changed WHERE title = 'Blocked' OR (SELECT count(*) FROM history)<0",'Fixture title is blocked.']);
      IrisSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['fixture-view','views','invariant',1,"SELECT id FROM changed WHERE name = 'Blocked'",'Fixture view is blocked.']);
      """)
    #expect(runtime.context.exception == nil)
    try await seed.close()
    try HubFixture.state.load(path: hubPath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let transport = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") },
      makeTransport: { _ in transport })
    try await model.connect(
      HubCredentials(endpoint: transport.endpoint, token: "fixture-scoped-token"), remember: false)
    model.table = "notes"
    await model.reload()
    #expect(model.canWrite)
    #expect(model.editingUnavailable == nil)
    let client = try #require(model.client)
    let context = try #require(model.editingContext)
    let original = try #require(model.rows.first?.record)
    try await model.refreshSavedViews(context: context)
    #expect(model.viewsWriteability?.writable == true)
    do {
      try await model.save(
        ["id": original["id"]!, "title": .string("Blocked")], original: original, context: context)
      Issue.record("An invariant-violating edit was accepted")
    } catch let error as WorkspaceError {
      #expect(error.violations.first?.rule == "fixture-title")
    }
    #expect(try await client.rows(table: "notes").first?.record == original)
    #expect(try await client.status().pendingUiEdits == 0)
    _ = try await model.save(
      ["id": original["id"]!, "title": .string("Allowed")], original: original, context: context)
    await model.synchronize()
    #expect(model.canWrite)
    #expect(
      HubFixture.state.record(table: "notes", id: original["id"]!.text)?["title"]
        == .string("Allowed"))

    _ = try await client.sync(using: transport, tables: ["history": false])
    await model.reload()
    #expect(!model.canWrite)
    #expect(model.editingUnavailable?.contains("history") == true)
    #expect(model.rows.first?.label == "Allowed")
    try await model.refreshSavedViews(context: context)
    #expect(model.viewsWriteability?.writable == true)
    await model.synchronize()
    #expect(model.canWrite)
    HubFixture.state.failPull("notes")
    await model.synchronize()
    #expect(model.canWrite)
    #expect(model.syncError?.contains("503") == true)
    #expect(model.syncPill.kind == .offline)
    #expect(model.editingUnavailable == nil)
    #expect(model.rows.first?.label == "Allowed")
    _ = try await model.save(
      ["id": original["id"]!, "title": .string("Saved offline")], original: nil, context: context)
    HubFixture.state.failPull(nil)
    await model.synchronize()
    #expect(model.canWrite)
    model.table = "history"
    #expect(!model.canWrite)
    await model.reload()
    #expect(!model.canWrite)
    #expect(model.writeability?.reason?.rule == "read_only")
    #expect(!model.rows.isEmpty)
    await model.close()
    #expect(!model.canWrite)
  }

  @Test func interruptedRoundKeepsFinishedTablesAndTheNextRoundCompletes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hubPath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: hubPath)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: hubPath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let transport = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let path = directory.appendingPathComponent("replica.sqlite").path
    let replica = try NativeWorkspace(path: path)
    HubFixture.state.failPull("notes")
    await #expect(throws: Error.self) { try await replica.sync(using: transport) }
    try await replica.close()
    // A failed request or round deadline keeps every table finished before it.
    let finished = try await DatabaseQueue(path: path).read {
      try String.fetchAll($0, sql: "SELECT tbl FROM _core_sync ORDER BY tbl")
    }
    #expect(finished.contains("catalog_properties"))
    #expect(!finished.contains("notes"))
    HubFixture.state.failPull(nil)
    let reopened = try NativeWorkspace(path: path)
    _ = try await reopened.sync(using: transport)
    #expect(try await reopened.status().lastSuccessfulSync != nil)
    try await reopened.close()
  }

  @Test func realCorePullEditPushAndTransportFailureRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixturePath = directory.appendingPathComponent("hub.sqlite").path
    let seed = try NativeWorkspace(path: fixturePath)
    try await seed.createSample()
    try await seed.close()
    try HubFixture.state.load(path: fixturePath)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let transport = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let path = directory.appendingPathComponent("replica.sqlite").path
    let replica = try NativeWorkspace(path: path)
    let first = try await replica.sync(using: transport)
    #expect(first.pulled > 0)
    #expect(first.rejected.isEmpty)
    #expect(try await replica.status().pendingUiEdits == 0)
    let row = try #require(try await replica.rows(table: "notes").first)
    _ = try await replica.write(
      table: "notes",
      patch: [
        "id": .string(row.id), "body": .string("# Native sync\n\nShared core, synthetic data."),
      ], expectedUpdatedAt: row.record["updated_at"]?.text)
    #expect(try await replica.status().pendingUiEdits == 1)
    HubFixture.state.setStatus(401)
    await #expect(throws: Error.self) { try await replica.sync(using: transport) }
    #expect(try await replica.status().pendingUiEdits == 1)
    HubFixture.state.setStatus(200)
    var progress: [WorkspaceSyncProgress] = []
    let second = try await replica.sync(using: transport, onProgress: { progress.append($0) })
    let uploads = progress.filter { $0.phase == "Uploading" && $0.table == "notes" }
    #expect(uploads.count >= 2)
    #expect((uploads.last?.processedRows ?? 0) > (uploads.first?.processedRows ?? 0))
    // Core reports the round through the bridge: every table, every row of the full pulls.
    let last = try #require(progress.last)
    #expect(last.tablesTotal > 3 && last.tablesDone == last.tablesTotal)
    #expect(last.rowsExpected != nil && last.rowsReceived == last.rowsExpected)
    #expect(
      progress.contains { $0.phase == "Downloading" && $0.table == "notes" && $0.processedRows > 0 }
    )
    #expect(try await replica.status().pendingUiEdits == 0)
    #expect(try await replica.status().lastSuccessfulSync != nil)
    #expect(second.pushed > 0)
    #expect(
      HubFixture.state.record(table: "notes", id: row.id)?["body"]
        == .string("# Native sync\n\nShared core, synthetic data."))
    #expect(HubFixture.state.rowCount(table: "history") == 1)
    let lock = try SyncFileLock(databasePath: path)
    await #expect(throws: Error.self) { try await replica.sync(using: transport) }
    withExtendedLifetime(lock) {}
    try await replica.close()
  }

  @Test func syncTimeLeftExtrapolatesAKnownDownloadOnly() {
    let start = Date(timeIntervalSince1970: 0)
    let cold = WorkspaceSyncProgress(
      phase: "Downloading", table: "people", page: 0, processedRows: 0, startedAt: start,
      tablesDone: 37, tablesTotal: 113, rowsReceived: 21_638, rowsExpected: 150_714)
    let left = try! #require(cold.remaining(at: start.addingTimeInterval(60)))
    #expect(abs(left - 357.9) < 1)
    #expect(cold.remaining(at: start.addingTimeInterval(2)) == nil)
    var early = cold
    early.rowsReceived = 1_000
    #expect(early.remaining(at: start.addingTimeInterval(60)) == nil)
    var changesOnly = cold
    changesOnly.rowsExpected = nil
    #expect(changesOnly.remaining(at: start.addingTimeInterval(60)) == nil)
    var finished = cold
    finished.tablesDone = 113
    #expect(finished.remaining(at: start.addingTimeInterval(60)) == nil)
  }

  @Test func errorsDoNotExposeResponseBodiesOrCredentialsAndReleaseLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HubFixture.self]
    let hub = try HubTransport(
      endpoint: "https://fixture.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let path = directory.appendingPathComponent("replica.sqlite").path
    let replica = try NativeWorkspace(path: path)
    for status in [401, 302, 500] {
      HubFixture.state.setStatus(status)
      do {
        _ = try await replica.sync(using: hub)
        Issue.record("Failed response accepted")
      } catch {
        #expect(error.localizedDescription.contains("Hub HTTP \(status)"))
        #expect(!error.localizedDescription.contains("private-body"))
      }
      let lock = try SyncFileLock(databasePath: path)
      withExtendedLifetime(lock) {}
    }
    HubFixture.state.setStatus(200)
    #expect(try await replica.sync(using: hub).pulled > 0)
    try await replica.close()
  }
}

private final class HubFixture: URLProtocol, @unchecked Sendable {
  static let state = FixtureState()
  override class func canInit(with request: URLRequest) -> Bool {
    ["fixture.invalid", "other.invalid"].contains(request.url?.host ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.state.reply(request)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "Date": formatter.string(from: Date())])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private final class FixtureState: @unchecked Sendable {
  private let lock = NSLock()
  private var tables: [String: [WorkspaceRecord]] = [:]
  private var schema: [WorkspaceRecord] = []
  private var status = 200
  private var failedPullTable: String?
  func setStatus(_ status: Int) { lock.withLock { self.status = status } }
  func failPull(_ table: String?) { lock.withLock { failedPullTable = table } }
  func record(table: String, id: String) -> WorkspaceRecord? {
    lock.withLock { tables[table]?.first { $0["id"]?.text == id } }
  }
  func rowCount(table: String) -> Int { lock.withLock { tables[table]?.count ?? 0 } }
  func changeRule(_ id: String, sql: String) {
    lock.withLock {
      guard let index = tables["catalog_rules"]?.firstIndex(where: { $0["id"]?.text == id }) else {
        return
      }
      tables["catalog_rules"]?[index]["sql"] = .string(sql)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      tables["catalog_rules"]?[index]["updated_at"] = .string(
        formatter.string(from: Date(timeIntervalSinceNow: 1)))
    }
  }
  @MainActor func load(path: String) throws {
    try lock.withLock {
      let bridge = try SQLiteBridge(path: path)
      defer { try? bridge.close() }
      let context = try #require(JSContext())
      try bridge.install(in: context)
      func records(_ sql: String) throws -> [WorkspaceRecord] {
        let result = context.objectForKeyedSubscript("IrisSql")?.invokeMethod(
          "all", withArguments: [sql])
        let json = try #require(
          context.objectForKeyedSubscript("JSON")?.invokeMethod(
            "stringify", withArguments: [result as Any])?.toString())
        return try JSONDecoder().decode([WorkspaceRecord].self, from: Data(json.utf8))
      }
      schema = try records("SELECT applied_at,ddl FROM _schema_log ORDER BY id")
      tables = [:]
      let existing = Set(
        try records("SELECT name FROM sqlite_schema WHERE type='table'").compactMap {
          $0["name"]?.text
        })
      for name in [
        "notes", "topics", "catalog_tables", "catalog_properties", "catalog_rules", "history",
        "views", "view_defaults", "sidebar_pins", "catalog_log", "provenance", "collated",
      ] where existing.contains(name) {
        tables[name] = try records("SELECT * FROM \(name)")
      }
      status = 200
      failedPullTable = nil
    }
  }
  func reply(_ request: URLRequest) throws -> (Int, Data) {
    try lock.withLock {
      if status != 200 { return (status, Data(#"{"error":"private-body"}"#.utf8)) }
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-scoped-token"
      else { return (401, Data("{}".utf8)) }
      if request.url?.path == "/v1/session", request.httpMethod == "GET" {
        return (200, Data(#"{"name":"Example device","scopes":["full"]}"#.utf8))
      }
      guard request.httpMethod == "POST" else { return (405, Data("{}".utf8)) }
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          bytes.append(contentsOf: buffer[..<count])
        }
      }
      let body = try JSONDecoder().decode(WorkspaceRecord.self, from: bytes)
      let table = body["table"]?.text ?? ""
      func asked(_ body: WorkspaceRecord) -> [String] {
        if case .array(let names) = body["tables"] { return names.compactMap { $0.text } }
        return []
      }
      let data: JSONValue
      switch request.url!.path {
      case "/v1/schema/pull": data = .object(["entries": .array(schema.map(JSONValue.object))])
      case "/v1/stats":
        data = .object(["tables": .object(tables.mapValues { .number(Double($0.count)) })])
      case "/v1/cursor":
        // Advertises batched pulls, as the deployed hub does.
        data = .object([
          // Every table asked gets a mark, as the deployed hub answers: core asks for
          // all of its tables, including ones this hub never seeded.
          "max_hub_at": .string(""), "tables": .object(asked(body).reduce(into: [:]) { $0[$1] = .string("") }),
          "pull_batch": .object([
            "items": .number(50), "rows": .number(5000), "bytes": .number(4_194_304),
          ]),
        ])
      case "/v1/rows/pull":
        func page(_ body: WorkspaceRecord) -> JSONValue {
          let table = body["table"]?.text ?? ""
          let limit = Int(body["limit"]?.text ?? "1000") ?? 1000
          let requestedID: String? =
            if case .object(let predicate) = body["where"] { predicate["id"]?.text } else { nil }
          let rows = Array(
            (tables[table] ?? []).filter { row in
              (requestedID == nil || row["id"]?.text == requestedID
                || (table == "collated"
                  && row["id"]?.text.lowercased() == requestedID?.lowercased()))
                && (body["after"] == nil || (row["id"]?.text ?? "") > (body["after"]?.text ?? ""))
            }.sorted { ($0["id"]?.text ?? "") < ($1["id"]?.text ?? "") }.prefix(limit))
          return .object([
            "rows": .array(rows.map(JSONValue.object)),
            "next_cursor": rows.count == limit ? (rows.last?["id"] ?? .null) : .null,
          ])
        }
        if case .array(let items) = body["batch"] {
          var pulls = items.compactMap { item -> WorkspaceRecord? in
            if case .object(let pull) = item { return pull } else { return nil }
          }
          // A failing table fails its own request; batches answer the prefix before it.
          if let failing = pulls.firstIndex(where: { $0["table"]?.text == failedPullTable }) {
            if failing == 0 { return (503, Data("{}".utf8)) }
            pulls = Array(pulls.prefix(failing))
          }
          data = .object(["batch": .array(pulls.map(page))])
        } else {
          if table == failedPullTable { return (503, Data("{}".utf8)) }
          data = page(body)
        }
      case "/v1/rows/push":
        guard case .array(let values) = body["rows"] else { throw URLError(.badServerResponse) }
        for case .object(let row) in values {
          tables[table]?.removeAll { $0["id"] == row["id"] }
          tables[table, default: []].append(row)
        }
        data = .object(["upserted": .number(Double(values.count)), "rejected": .array([])])
      default: throw URLError(.badURL)
      }
      return (200, try JSONEncoder().encode(data))
    }
  }
}
