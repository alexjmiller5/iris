import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct WorkspaceLinkTests {
  @Test func transientLinkAppliesQueryAndKeepsTheDisplayedSavedRevision() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    let workspace = try #require(model.client)
    let context = try #require(model.editingContext)
    let saved = try await workspace.saveView(CoreSaveViewArgs(table: context.table, name: "Stored",
      definition: CoreSavedViewDefinition(version: 1, columns: ["title"])))
    try model.applySavedView(saved, context: context)
    model.search = "Synthetic query"
    let link = try NativeDeepLink(url: model.linkURL(
      for: NativeDestination(table: context.table, viewID: saved.id), context: context))
    #expect(link.destination.state != nil)
    let before = try await workspace.status()
    let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
      link.destination, isCurrent: { true })
    _ = try model.activateDestination(resolved, workspace: workspace, generation: model.workspaceGeneration)
    #expect(model.search == "Synthetic query")
    #expect(model.appliedView == saved)
    #expect(model.viewModified)
    #expect(
      try await workspace.listViews(table: context.table).views.filter { $0.name != "Default view" }
        == [saved])
    #expect(try await workspace.status() == before)
    await model.close()
  }

  @Test func sourceLinkUsesPreservedMappingAndNativeDestinationGuards() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let target = try #require(try await workspace.rows(table: "notes").first)
    runtime.context.setObject(target.id, forKeyedSubscript: "fixtureTarget" as NSString)
    runtime.context.evaluateScript(
      #"""
      IrisSql.run("CREATE TABLE provenance (id TEXT PRIMARY KEY,from_kind TEXT,from_ref TEXT,to_kind TEXT,to_ref TEXT,rel TEXT,field TEXT,deleted_at TEXT)");
      IrisSql.run("INSERT INTO provenance(id,from_kind,from_ref,to_kind,to_ref,rel) VALUES ('edge','notion','11111111222233334444555555555555','notes',?,'imported_from')", [fixtureTarget]);
      """#)
    #expect(runtime.context.exception == nil)
    let result = try await workspace.resolveSourceLink(
      "https://app.notion.com/p/Imported-11111111222233334444555555555555")
    let mapped = try #require(result.destination)
    #expect(mapped.table == "notes" && mapped.row == target.id)
    let destination = try await NativeDestinationResolver(workspace: workspace).resolve(
      NativeDestination(table: mapped.table, rowID: mapped.row), isCurrent: { true })
    #expect(destination.row?.id == target.id)
    #expect(
      try await workspace.resolveSourceLink("https://example.com/reference").destination == nil)
    try await workspace.close()
  }
  @Test func explicitRecordIdentityUsesCatalogAndFreshNativeNavigation() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let target = try #require(try await workspace.rows(table: "notes").first)
    let result = try await workspace.resolveSourceLink("notes/" + target.id)
    let mapped = try #require(result.destination)
    #expect(mapped.table == "notes" && mapped.row == target.id)
    let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
      NativeDestination(table: mapped.table, rowID: mapped.row), isCurrent: { true })
    #expect(resolved.row?.id == target.id)
    #expect(try await workspace.resolveSourceLink("notes/missing").destination == nil)
    #expect(try await workspace.resolveSourceLink("sqlite_master/notes").destination == nil)
    try await workspace.close()
  }

  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func localIdentityIsCreatedOnlyByCopyAndSurvivesReopen() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    let store = NativeLinkIdentityStore(root: root, workspace: file)
    let model = WorkspaceModel(localURL: { file })
    await model.open()
    #expect(model.linkBinding == nil && model.canCopyLink)
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
    let destination = NativeDestination(table: "notes", rowID: try #require(model.rows.first?.id))
    let url = try model.linkURL(for: destination, context: model.editingContext)
    let link = try NativeDeepLink(url: url)
    #expect(try store.load() == link.binding)
    #expect(try model.linkedDestination(link) == destination)
    #expect(model.recents?.destinations.isEmpty == true)
    await model.close()
    #expect(model.linkBinding == nil && !model.canCopyLink)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    await model.open()
    #expect(model.linkBinding == link.binding)
    #expect(try model.linkURL(for: destination, context: model.editingContext) == url)
    await model.close()
  }

  @Test func sampleReplacementCannotUseOldBindingOrEditorContext() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    let context = try #require(model.editingContext)
    let destination = NativeDestination(table: "notes")
    let link = try NativeDeepLink(url: model.linkURL(for: destination, context: context))
    await model.open(demo: true)
    #expect(model.linkBinding == nil && !model.canCopyLink)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    #expect(throws: WorkspaceError.self) { try model.linkURL(for: destination, context: context) }
    #expect(throws: WorkspaceError.self) {
      try model.linkURL(for: destination, context: model.editingContext)
    }
    await model.close()
  }

  @Test func wrongWorkspaceDoesNotAdoptAnIncomingIdentityOrChangeTheQuery() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    model.search = "Retain this query"
    let query = model.queryKey
    let link = try NativeDeepLink(
      destination: NativeDestination(table: "topics"), workspace: .local(UUID()))
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    #expect(model.linkBinding == nil && model.queryKey == query)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("link-identities").path))
    await model.close()
  }

  @Test func copyRejectsByteDistinctTablesEvenWhenSwiftConsidersThemEqual() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    model.table = "\u{00e9}"
    let context = try #require(model.editingContext)
    #expect(throws: WorkspaceError.self) {
      try model.linkURL(for: NativeDestination(table: "e\u{0301}"), context: context)
    }
    model.table = "e\u{0301}"
    #expect(throws: WorkspaceError.self) {
      try model.linkURL(for: NativeDestination(table: "\u{00e9}"), context: context)
    }
    #expect(model.linkBinding == nil)
    await model.close()
  }

  @Test(arguments: [false, true])
  func unreadIdentityDoesNotBlockOpeningAndCopyNeverOverwritesIt(widgetsEnabled: Bool) async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    let store = NativeLinkIdentityStore(root: root, workspace: file)
    try FileManager.default.createDirectory(
      at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{\"version\":99,\"private\":\"unread\"}".utf8)
    try bytes.write(to: store.file)
    let model = WorkspaceModel(
      localURL: { file },
      widgetLibrary: widgetsEnabled ? WidgetLibrary(root: root.appendingPathComponent("shared")) : nil)
    await model.open()
    #expect(model.client != nil && !model.rows.isEmpty && model.linkError != nil)
    #expect(throws: WorkspaceError.self) {
      try model.linkURL(for: NativeDestination(table: "notes"), context: model.editingContext)
    }
    #expect(try Data(contentsOf: store.file) == bytes)
    await model.close()
  }

  @Test func replacingThePhysicalFileRejectsOldLinksBeforeAnyNewCopy() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    let model = WorkspaceModel(localURL: { file })
    await model.open()
    let link = try NativeDeepLink(
      url: model.linkURL(for: NativeDestination(table: "notes"), context: model.editingContext))
    await model.close()
    try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old.sqlite"))
    await model.open()
    #expect(model.linkBinding == nil)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    let newLink = try NativeDeepLink(
      url: model.linkURL(for: NativeDestination(table: "notes"), context: model.editingContext))
    #expect(newLink.binding != link.binding)
    await model.close()
  }

  @Test func fileReplacementWhileOpenCannotRebindTheStillOpenClientOnCopy() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("local.sqlite")
    let replacement = root.appendingPathComponent("replacement.sqlite")
    let fresh = try NativeWorkspace(path: replacement.path)
    try await fresh.createSample()
    try await fresh.close()
    let model = WorkspaceModel(localURL: { file })
    await model.open()
    let destination = NativeDestination(table: "notes")
    let link = try NativeDeepLink(
      url: model.linkURL(for: destination, context: model.editingContext))
    let store = NativeLinkIdentityStore(root: root, workspace: file)
    let before = try Data(contentsOf: store.file)
    try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("retired.sqlite"))
    try FileManager.default.moveItem(at: replacement, to: file)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    #expect(throws: WorkspaceError.self) {
      try model.linkURL(for: destination, context: model.editingContext)
    }
    #expect(try Data(contentsOf: store.file) == before)
    await model.close()
  }

  @Test func forgettingAnOfflineReplicaRetainsItsBindingUntilClientReplacement() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = "https://links.invalid"
    let path = WorkspaceModel.replicaURL(root: root, endpoint: endpoint)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workspace = try NativeWorkspace(path: path.path)
    try await workspace.createSample()
    try await workspace.close()
    let credentials = MemoryHubCredentials(
      HubCredentials(endpoint: endpoint, token: "fixture-device"))
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      makeTransport: {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LinkOfflineFixture.self]
        return try HubTransport(endpoint: $0.endpoint, token: $0.token, configuration: config)
      }, credentialStore: credentials)
    await model.resumeConnection()
    let client = try #require(model.client)
    let link = try NativeDeepLink(
      url: model.linkURL(for: NativeDestination(table: "notes"), context: model.editingContext))
    #expect(link.binding == .replica(canonicalEndpoint: endpoint))
    try await model.forgetConnection()
    #expect(!model.isReplica && model.connection == nil && model.client === client)
    #expect(try model.linkedDestination(link) == NativeDestination(table: "notes"))
    #expect(try model.linkURL(for: link.destination, context: model.editingContext) == link.url)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("link-identities").path))
    await model.open()
    #expect(model.linkBinding == nil)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    await model.close()
  }

  @Test func matchedLinksStillResolveFreshFullRowsAndDoNotInstallByThemselves() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    let client = try #require(model.client)
    let row = try #require(model.rows.first)
    let destination = NativeDestination(table: "notes", rowID: row.id)
    let link = try NativeDeepLink(
      url: model.linkURL(for: destination, context: model.editingContext))
    _ = try await client.write(
      table: "notes", patch: ["id": .string(row.id), "body": .string("Fresh complete body")])
    model.search = "unchanged until install"
    let resolved = try await NativeDestinationResolver(workspace: client).resolve(
      model.linkedDestination(link), isCurrent: { true })
    #expect(resolved.row?.record["body"] == .string("Fresh complete body"))
    #expect(
      model.search == "unchanged until install" && model.recents?.destinations.isEmpty == true)
    _ = try model.activateDestination(
      resolved, workspace: client, generation: model.workspaceGeneration)
    #expect(model.search.isEmpty)
    await model.close()
  }

  @Test func pendingSavedViewWriteBlocksLinkMatchingAndCopy() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("local.sqlite") })
    await model.open()
    let destination = NativeDestination(table: "notes")
    let context = try #require(model.editingContext)
    let link = try NativeDeepLink(url: model.linkURL(for: destination, context: context))
    var finished = false
    let task = Task {
      defer { finished = true }
      try await model.saveCurrentView(name: "Pending view", update: false, context: context)
    }
    while !model.savingView && !finished { await Task.yield() }
    #expect(model.savingView)
    #expect(throws: WorkspaceError.self) { try model.linkedDestination(link) }
    #expect(throws: WorkspaceError.self) { try model.linkURL(for: destination, context: context) }
    try await task.value
    #expect(try model.linkedDestination(link) == destination)
    await model.close()
  }
}

private final class LinkOfflineFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
