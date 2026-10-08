import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct EnrollmentConnectionTests {
  #if os(macOS)
    @Test(arguments: ["selection", "keychain"])
    func failedConnectionPreservesSelectedDatabaseAndCredential(reason: String) async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      let bookmark = directory.appendingPathComponent("selected-database.bookmark")
      defer {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bookmark.path)
        try? FileManager.default.removeItem(at: directory)
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("selected.sqlite")
      let seed = try NativeWorkspace(path: file.path)
      try await seed.createSample()
      try await seed.close()
      let old = HubCredentials(endpoint: "https://saved.invalid", token: "saved-fixture")
      let store = MemoryHubCredentials(old)
      let model = makeModel(directory, store: store)
      await model.open(url: file)
      do {
        let before = try #require(model.client)
        let bytes = try Data(contentsOf: bookmark)
        if reason == "selection" {
          try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bookmark.path)
        } else {
          store.failSave = true
        }
        await #expect(throws: Error.self) {
          try await model.connect(
            HubCredentials(endpoint: "https://full.invalid", token: "candidate-fixture"),
            synchronizeAfter: false)
        }
        #expect(model.client === before)
        #expect(store.value == old)
        #expect(store.saves == (reason == "keychain" ? 1 : 0))
        #expect(try Data(contentsOf: bookmark) == bytes)
        #expect(
          try LocalDatabaseSelection(root: directory).load()?.resolvingSymlinksInPath().path
            == file.resolvingSymlinksInPath().path)
      } catch {
        await model.close()
        throw error
      }
      await model.close()
    }
  #endif

  @Test(arguments: ["admin", "restricted", "offline", "keychain"])
  func rejectedCandidatePreservesTheOpenWorkspaceAndSavedCredential(reason: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = HubCredentials(endpoint: "https://saved.invalid", token: "saved-fixture")
    let store = MemoryHubCredentials(old)
    let model = makeModel(directory, store: store)
    await model.open(demo: true)
    let before = try #require(model.client)
    let rows = model.rows
    let generation = model.workspaceGeneration
    store.failSave = reason == "keychain"
    await #expect(throws: Error.self) {
      try await model.connect(
        HubCredentials(endpoint: "https://\(reason).invalid", token: "candidate-fixture"))
    }
    #expect(model.client === before)
    #expect(model.rows == rows)
    #expect(model.workspaceGeneration == generation)
    #expect(store.value == old)
    #expect(store.saves == (reason == "keychain" ? 1 : 0))
    #expect(!(try await before.rows(table: "notes")).isEmpty)
    await model.close()
  }

  @Test func establishedKeychainReplicaReopensOfflineWithoutSessionValidation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = HubCredentials(endpoint: "https://offline.invalid", token: "saved-fixture")
    let store = MemoryHubCredentials(stored)
    // Established replica data lives under the canonical endpoint identity.
    let path = WorkspaceModel.replicaURL(root: directory, endpoint: stored.endpoint)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workspace = try NativeWorkspace(path: path.path)
    try await workspace.createSample()
    try await workspace.close()
    let model = makeModel(directory, store: store)
    await model.resumeConnection()
    #expect(model.connection == stored)
    #expect(model.isReplica)
    #expect(
      model.syncPill.kind == .offline,
      "The failed sync should remain visible alongside cached records")
    model.table = "notes"
    await model.reload()
    #expect(!model.rows.isEmpty)
    #expect(store.saves == 0 && store.removals == 0)
    await model.close()
  }

  @Test func cancelOrWorkspaceReplacementBeforeCandidateCommitCannotInstall() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MemoryHubCredentials(nil)
    let model = makeModel(directory, store: store)
    await model.open(demo: true)
    let old = model.client
    await #expect(throws: Error.self) {
      try await model.connect(
        HubCredentials(endpoint: "https://full.invalid", token: "candidate-fixture"),
        isCurrent: { false })
    }
    #expect(model.client === old && store.saves == 0)
    await model.close()
  }

  @Test func lateSessionValidationCannotReplaceANewerWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MemoryHubCredentials(nil)
    let model = makeModel(directory, store: store)
    await model.open(demo: true)
    let task = Task {
      try await model.connect(
        HubCredentials(endpoint: "https://held.invalid", token: "candidate-fixture"))
    }
    for _ in 0..<10000 {
      if ConnectionSessionFixture.gate.hasRequest { break }
      await Task.yield()
    }
    #expect(ConnectionSessionFixture.gate.hasRequest)
    await model.open(demo: true)
    let replacement = model.client
    ConnectionSessionFixture.gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(model.client === replacement && store.saves == 0)
    await model.close()
  }

  @Test func cachedRowsAppearBeforeOfflineSyncFinishesAndLateSyncCannotReplaceContext() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = HubCredentials(endpoint: "https://slow-sync.invalid", token: "saved-fixture")
    let store = MemoryHubCredentials(credentials)
    let path = WorkspaceModel.replicaURL(root: directory, endpoint: credentials.endpoint)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let seed = try NativeWorkspace(path: path.path)
    try await seed.createSample()
    try await seed.close()
    let model = makeModel(directory, store: store)
    let task = Task { await model.resumeConnection() }
    for _ in 0..<10000 {
      if ConnectionSessionFixture.gate.hasRequest { break }
      await Task.yield()
    }
    #expect(ConnectionSessionFixture.gate.hasRequest)
    #expect(
      !model.rows.isEmpty,
      "Cached records must be usable while the offline request is still pending")
    let old = model.client
    let replacement = try NativeWorkspace(path: ":memory:")
    try await replacement.createSample()
    model.client = replacement
    model.catalog = try await replacement.catalog()
    model.table = "notes"
    await model.reload()
    let rows = model.rows
    ConnectionSessionFixture.gate.release()
    await task.value
    #expect(model.client === replacement && model.rows == rows)
    #expect(
      model.error == nil && model.syncError == nil,
      "An old connection's failure must not become the new workspace's error")
    #expect(!model.syncing)
    try await old?.close()
    await model.close()
  }

  private func makeModel(_ directory: URL, store: MemoryHubCredentials) -> WorkspaceModel {
    WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") },
      makeTransport: {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionSessionFixture.self]
        return try HubTransport(endpoint: $0.endpoint, token: $0.token, configuration: config)
      }, credentialStore: store)
  }
}

final class MemoryHubCredentials: HubCredentialStorage {
  var value: HubCredentials?
  var failSave = false
  var saves = 0
  var removals = 0
  init(_ value: HubCredentials?) { self.value = value }
  func load() throws -> HubCredentials? { value }
  func save(_ value: HubCredentials) throws {
    saves += 1
    if failSave { throw WorkspaceError(message: "Synthetic Keychain failure", violations: []) }
    self.value = value
  }
  func remove() throws {
    removals += 1
    value = nil
  }
}

private final class ConnectionSessionFixture: URLProtocol, @unchecked Sendable {
  static let gate = SessionGate()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    if request.url?.host == "held.invalid" || request.url?.host == "slow-sync.invalid" {
      Self.gate.hold(self)
      return
    }
    respond()
  }
  func respond() {
    if request.url?.host == "offline.invalid" || request.url?.path != "/v1/session" {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let name = request.url?.host == "admin.invalid" ? "admin" : "Example device"
    let scopes = request.url?.host == "restricted.invalid" ? ["table:widgets:read"] : ["full"]
    let data = try! JSONSerialization.data(withJSONObject: ["name": name, "scopes": scopes])
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class SessionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: ConnectionSessionFixture?
  var hasRequest: Bool { lock.withLock { pending != nil } }
  func hold(_ request: ConnectionSessionFixture) { lock.withLock { pending = request } }
  func release() {
    let request = lock.withLock {
      let value = pending
      pending = nil
      return value
    }
    request?.respond()
  }
}
