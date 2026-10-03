import Foundation
import Testing

@testable import LifeKit

@MainActor
struct WorkspaceRecentsTests {
  private func root() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func sampleHistoryStartsEmptyOnlyRecordsExplicitCompletionAndNeverCreatesPreferences() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = WorkspaceModel(localURL: { directory.appendingPathComponent("local.sqlite") })
    await model.open(demo: true)
    let recents = try #require(model.recents)
    #expect(recents.destinations.isEmpty)
    await model.reload()
    await recents.refresh()
    #expect(recents.destinations.isEmpty)
    await recents.navigationSucceeded(NativeDestination(table: "notes"))
    #expect(recents.destinations == [NativeDestination(table: "notes")])
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("recents").path))
    await model.close()
    #expect(model.recents == nil)
    #expect(recents.entries.isEmpty)
    await model.open(demo: true)
    #expect(model.recents?.destinations.isEmpty == true)
    await recents.navigationSucceeded(NativeDestination(table: "closed-workspace"))
    #expect(recents.destinations == [NativeDestination(table: "notes")])
    #expect(model.recents?.destinations.isEmpty == true)
    await model.close()
  }

  @Test func localAndExternalWorkspacesKeepSeparateHistoryAcrossReopen() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = directory.appendingPathComponent("local.sqlite")
    let external = directory.appendingPathComponent("external.sqlite")
    let model = WorkspaceModel(localURL: { local })
    await model.open()
    let recent = try #require(model.recents)
    let id = try #require(model.rows.first?.id)
    let destination = NativeDestination(table: "notes", rowID: id)
    await recent.navigationSucceeded(destination)
    let externalWorkspace = try NativeWorkspace(path: external.path)
    try await externalWorkspace.createSample()
    try await externalWorkspace.close()
    await model.open(url: external)
    #expect(model.recents?.destinations.isEmpty == true)
    await recent.navigationSucceeded(NativeDestination(table: "wrong-workspace"))
    #expect(recent.destinations == [destination])
    await model.recents?.navigationSucceeded(NativeDestination(table: "notes"))
    await model.open()
    #expect(model.recents?.destinations == [destination])
    await model.recents?.refresh()
    #expect(model.recents?.entries.first?.label == "A place to start")
    await model.close()
  }

  @Test func unreadPreferencesDoNotBlockOpeningOrReplaceUnseenHistory() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = directory.appendingPathComponent("local.sqlite")
    let store = NativeRecentsStore(root: directory, workspace: local)
    try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{\"version\":99,\"entries\":[]}".utf8)
    try bytes.write(to: store.file)
    let model = WorkspaceModel(localURL: { local })
    await model.open()
    #expect(model.client != nil && !model.rows.isEmpty)
    let recents = try #require(model.recents)
    #expect(recents.storageError != nil)
    await recents.navigationSucceeded(NativeDestination(table: "notes"))
    #expect(recents.destinations == [NativeDestination(table: "notes")])
    #expect(try Data(contentsOf: store.file) == bytes)
    await model.close()
  }

  @Test func metadataRefreshReadsNewLabelsWithoutReplacingRowsOrViewState() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = WorkspaceModel(localURL: { directory.appendingPathComponent("local.sqlite") })
    await model.open()
    let workspace = try #require(model.client)
    let recents = try #require(model.recents)
    let row = try #require(model.rows.first)
    let destination = NativeDestination(table: "notes", rowID: row.id)
    await recents.navigationSucceeded(destination)
    let store = NativeRecentsStore(root: directory, workspace: directory.appendingPathComponent("local.sqlite"))
    let before = try Data(contentsOf: store.file)
    model.search = "keep query"
    model.sortColumn = "title"
    let query = model.queryKey
    let rows = model.rows
    _ = try await workspace.write(table: "notes", patch: ["id": .string(row.id), "title": .string("Current title")])
    await recents.refresh()
    #expect(recents.entries.first?.label == "Current title")
    #expect(recents.destinations == [destination])
    #expect(model.queryKey == query && model.rows == rows)
    #expect(try Data(contentsOf: store.file) == before)
    await model.close()
  }

  @Test func forgettingCredentialKeepsTheSameLocalHistoryUsable() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = WorkspaceModel(localURL: { directory.appendingPathComponent("local.sqlite") },
      credentialStore: MemoryHubCredentials(nil))
    await model.open(demo: true)
    let recents = try #require(model.recents)
    try model.forgetConnection()
    await recents.navigationSucceeded(NativeDestination(table: "notes"))
    #expect(model.recents === recents)
    #expect(recents.entries.first?.label == "notes")
    await model.close()
  }

  @Test func reopenedOfflineReplicasUseTheirOwnPreferenceIdentityAndFreshLabels() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = MemoryHubCredentials(nil)
    var expected: [NativeDestination] = []
    for endpoint in ["https://first.invalid", "https://second.invalid"] {
      let path = WorkspaceModel.replicaURL(root: directory, endpoint: endpoint)
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let workspace = try NativeWorkspace(path: path.path)
      try await workspace.createSample()
      let row = try await workspace.write(table: "notes", patch: ["title": .string("Cached " + endpoint)])
      let destination = NativeDestination(table: "notes", rowID: try #require(row["id"]?.text))
      expected.append(destination)
      let store = NativeRecentsStore(root: directory, workspace: path)
      _ = try store.load()
      _ = try store.update { _ in [destination] }
      try await workspace.close()
    }
    let model = WorkspaceModel(localURL: { directory.appendingPathComponent("local.sqlite") },
      makeTransport: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecentsOfflineFixture.self]
        return try HubTransport(endpoint: $0.endpoint, token: $0.token, configuration: configuration)
      }, credentialStore: credentials)
    var previous: NativeRecentsModel?
    for (index, endpoint) in ["https://first.invalid", "https://second.invalid"].enumerated() {
      credentials.value = HubCredentials(endpoint: endpoint, token: "fixture-device")
      await model.resumeConnection()
      #expect(model.isReplica && model.error != nil)
      let recents = try #require(model.recents)
      await recents.refresh()
      #expect(recents.destinations == [expected[index]])
      #expect(recents.entries.first?.label == "Cached " + endpoint)
      if let previous { #expect(previous.entries.isEmpty) }
      previous = recents
    }
    await model.close()
  }
}

private final class RecentsOfflineFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}
