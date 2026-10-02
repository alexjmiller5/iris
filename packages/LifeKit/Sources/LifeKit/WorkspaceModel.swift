import CryptoKit
import Foundation
import Observation

struct WorkspaceEditingContext {
  let workspace: NativeWorkspace
  let table: String
}

@Observable @MainActor
final class WorkspaceModel {
  var client: NativeWorkspace?
  var catalog: WorkspaceCatalog?
  var table: String?
  var rows: [WorkspaceRow] = []
  var search = ""
  var trash = false
  var loading = false
  var error: String?
  var location = ""
  var canLoadMore = false
  var syncing = false
  var syncResult: WorkspaceSyncResult?
  var syncStatus: WorkspaceSyncStatus?
  var connection: HubCredentials?
  var isReplica = false
  var groups: [String: String] = [:]
  let services = HubServicesModel()
  private var groupsURL: URL?
  private var transport: HubTransport?
  private var revision = 0
  private var scopedURL: URL?

  var editingContext: WorkspaceEditingContext? {
    guard let client, let table else { return nil }
    return WorkspaceEditingContext(workspace: client, table: table)
  }
  var tables: [WorkspaceRecord] { catalog?.tables ?? [] }
  var properties: [WorkspaceRecord] {
    (catalog?.properties ?? []).filter { $0["tbl"]?.text == table }.sorted {
      let left = Double($0["sort"]?.text ?? "") ?? 0
      let right = Double($1["sort"]?.text ?? "") ?? 0
      return left == right ? ($0["col"]?.text ?? "") < ($1["col"]?.text ?? "") : left < right
    }
  }
  var rules: [WorkspaceRecord] {
    (catalog?.rules ?? []).filter { $0["tbl"]?.text == table || $0["scope"]?.text == "estate" }
  }
  var canWrite: Bool {
    guard let table else { return false }
    return tables.first(where: { $0["id"]?.text == table })?["readOnly"] == .bool(false)
      && !properties.isEmpty
  }

  static func localURL() throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent("life-ui", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("local.sqlite")
  }

  func open(demo: Bool = false, url: URL? = nil) async {
    loading = true
    error = nil
    transport = nil
    services.configure(workspace: nil, transport: nil)
    isReplica = false
    syncResult = nil
    syncStatus = nil
    do {
      if client != nil { try await client?.close() }
      scopedURL?.stopAccessingSecurityScopedResource()
      scopedURL = nil
      let path: String
      let seed: Bool
      if demo {
        path = ":memory:"
        seed = true
      } else {
        let file = try url ?? Self.localURL()
        if url != nil, file.startAccessingSecurityScopedResource() { scopedURL = file }
        path = file.path
        seed = url == nil && !FileManager.default.fileExists(atPath: path)
      }
      try loadGroups(workspace: demo ? nil : path)
      let workspace = try NativeWorkspace(path: path)
      do {
        if seed { try await workspace.createSample() }
        catalog = try await workspace.catalog()
      } catch {
        try? await workspace.close()
        throw error
      }
      client = workspace
      location =
        demo
        ? "Sample workspace · temporary"
        : url == nil
          ? "Local workspace · saved on this device" : "Local database · \(url!.lastPathComponent)"
      table =
        tables.first(where: { $0["id"]?.text == "notes" })?["id"]?.text ?? tables.first?["id"]?.text
      search = ""
      trash = false
      await reload()
    } catch {
      self.error = error.localizedDescription
      client = nil
    }
    loading = false
  }

  func reload(more: Bool = false) async {
    guard let client, let table else {
      rows = []
      return
    }
    revision += 1
    let request = revision
    loading = true
    error = nil
    do {
      let result = try await client.rows(
        table: table, search: search, trash: trash, offset: more ? rows.count : 0)
      let status = isReplica ? try await client.status() : nil
      guard request == revision else { return }
      syncStatus = status
      rows = more ? rows + result : result
      canLoadMore = result.count == 100
    } catch {
      guard request == revision else { return }
      self.error = error.localizedDescription
      if !more { rows = [] }
    }
    loading = false
  }

  func save(_ patch: WorkspaceRecord, original: WorkspaceRecord?, context: WorkspaceEditingContext?)
    async throws
  {
    guard let client, let table else {
      throw WorkspaceError(message: "Open a workspace before saving.", violations: [])
    }
    guard let context, context.workspace === client, context.table == table else {
      throw WorkspaceError(
        message: "The workspace or table changed. Reopen the record before saving.", violations: [])
    }
    _ = try await context.workspace.write(
      table: context.table, patch: patch, expectedUpdatedAt: original?["updated_at"]?.text)
    await reload()
  }

  private func loadGroups(workspace: String?) throws {
    groups = [:]
    groupsURL = nil
    guard let workspace else { return }
    let name = SHA256.hash(data: Data(workspace.utf8)).map { String(format: "%02x", $0) }.joined()
    let url = try Self.localURL().deletingLastPathComponent().appendingPathComponent(
      "groups-" + name + ".json")
    groupsURL = url
    if FileManager.default.fileExists(atPath: url.path) {
      groups = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
  }

  func saveGroups(_ groups: [String: String]) {
    let tableIDs = Set(tables.compactMap { $0["id"]?.text })
    let next = groups.filter { tableIDs.contains($0.key) && !$0.value.isEmpty }
    do {
      if let groupsURL { try JSONEncoder().encode(next).write(to: groupsURL, options: .atomic) }
      self.groups = next
    } catch { self.error = "Could not save table groups: " + error.localizedDescription }
  }

  func resumeConnection() async {
    do {
      if let saved = try HubCredentialStore().load() { try await connect(saved, remember: false) }
    } catch { self.error = error.localizedDescription }
  }

  func connect(_ credentials: HubCredentials, remember: Bool = true) async throws {
    let hub = try HubTransport(endpoint: credentials.endpoint, token: credentials.token)
    let canonical = HubCredentials(endpoint: hub.endpoint, token: credentials.token)
    if remember { try HubCredentialStore().save(canonical) }
    services.configure(workspace: nil, transport: nil)
    try await client?.close()
    client = nil
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
    let directory = try Self.localURL().deletingLastPathComponent().appendingPathComponent(
      "replicas", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = SHA256.hash(data: Data(hub.endpoint.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let path = directory.appendingPathComponent(name + ".sqlite").path
    try loadGroups(workspace: path)
    client = try NativeWorkspace(path: path)
    transport = hub
    services.configure(workspace: client, transport: hub)
    connection = canonical
    isReplica = true
    location = "Hub workspace · local replica"
    table = nil
    rows = []
    search = ""
    trash = false
    await synchronize()
  }

  func synchronize() async {
    guard let client, let transport, !syncing else { return }
    syncing = true
    error = nil
    do {
      syncResult = try await client.sync(using: transport)
      catalog = try await client.catalog()
      if !tables.contains(where: { $0["id"]?.text == table }) {
        table =
          tables.first(where: { $0["readOnly"] == .bool(false) })?["id"]?.text
          ?? tables.first?["id"]?.text
      }
      await reload()
    } catch {
      // Keep the replica and queued edits available offline after a failed request.
      catalog = try? await client.catalog()
      if table == nil { table = tables.first?["id"]?.text }
      await reload()
      self.error = error.localizedDescription
    }
    syncing = false
  }

  func forgetConnection() throws {
    try HubCredentialStore().remove()
    connection = nil
    transport = nil
    services.configure(workspace: nil, transport: nil)
    isReplica = false
  }

  func close() async {
    services.configure(workspace: nil, transport: nil)
    do { try await client?.close() } catch {
      self.error = error.localizedDescription
      return
    }
    client = nil
    transport = nil
    isReplica = false
    syncResult = nil
    syncStatus = nil
    catalog = nil
    rows = []
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
  }
}
