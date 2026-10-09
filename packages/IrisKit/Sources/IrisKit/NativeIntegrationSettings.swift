import CryptoKit
import Foundation
import Observation

#if canImport(CoreSpotlight)
  import CoreSpotlight
#endif

struct SpotlightItem: Equatable, Sendable {
  /// A `iris://open/v1` link: identities only, never record content.
  let id: String
  let title: String
}

@MainActor protocol SpotlightIndexing: AnyObject {
  func replace(domain: String, items: [SpotlightItem]) async throws
  /// Domain identifiers are hierarchical: removing a workspace removes its tables.
  func remove(domains: [String]) async throws
}

struct LookupHit: Sendable {
  let title: String
  let url: URL
}

/// Durable per-workspace choices for system integrations: which tables offer titles
/// to Spotlight, which table answers Shortcuts lookups and which enabled widget source
/// is the in-app daily section. Only identities are stored; content stays in the replica.
@Observable @MainActor final class NativeIntegrationSettings {
  private(set) var spotlightTables: [String] = []
  private(set) var lookupTable: String?
  private(set) var dailySource: NativeWidgetSelection?
  private(set) var busy = false
  private(set) var error: String?
  private let workspace: NativeWorkspace
  private let workspaceID: String
  private let binding: NativeWorkspaceBinding
  private let preferencesURL: URL
  private let spotlight: SpotlightIndexing?
  private var unreadable = false
  private var refreshTask: Task<Void, Never>?
  private var alive = true
  private struct Preferences: Codable {
    let version: Int
    let workspaceID: String
    let spotlightTables: [String]
    let lookupTable: String?
    let dailySource: NativeWidgetSelection?
  }

  init(
    workspace: NativeWorkspace, workspaceID: String, binding: NativeWorkspaceBinding,
    preferencesURL: URL, spotlight: SpotlightIndexing? = nil
  ) {
    self.workspace = workspace
    self.workspaceID = workspaceID
    self.binding = binding
    self.preferencesURL = preferencesURL
    self.spotlight = spotlight
    do {
      guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return }
      let data = try Data(contentsOf: preferencesURL)
      let saved = try JSONDecoder().decode(Preferences.self, from: data)
      guard data.count <= 65536, saved.version == 1,
        saved.workspaceID.utf8.elementsEqual(workspaceID.utf8)
      else { throw Self.failure }
      spotlightTables = saved.spotlightTables
      lookupTable = saved.lookupTable
      dailySource = saved.dailySource
    } catch {
      unreadable = true
      self.error = "Search and Shortcuts settings could not be read. The saved file has been kept."
    }
  }

  func spotlightDomain(table: String) -> String {
    Self.domain(workspaceID) + "." + Self.hash(table)
  }

  @discardableResult func setSpotlightTables(_ tables: [String]) async -> Bool {
    guard alive, !busy, tables.count <= 32, Set(tables).count == tables.count,
      tables.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 })
    else { return false }
    busy = true
    defer { busy = false }
    let removed = spotlightTables.filter { !tables.contains($0) }
    do {
      // Remove before saving, so a failed save never leaves disabled titles searchable.
      try await spotlight?.remove(domains: removed.map(spotlightDomain))
      try save(spotlightTables: tables)
      spotlightTables = tables
      try await reindex()
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult func setLookupTable(_ table: String?) -> Bool {
    guard alive, table.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { return false }
    do {
      try save(lookupTable: .some(table))
      lookupTable = table
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  @discardableResult func setDailySource(_ source: NativeWidgetSelection?) -> Bool {
    guard alive else { return false }
    do {
      try save(dailySource: .some(source))
      dailySource = source
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  /// Display-title matches in the configured table only; excerpts never leave the app.
  func lookUp(_ text: String) async throws -> [LookupHit] {
    guard let table = lookupTable else {
      throw WorkspaceError(
        message: "Choose a lookup table in Iris's Widgets and Search settings.", violations: [])
    }
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf8.count <= 256 else { return [] }
    return try await workspace.search(CoreSearchArgs(text: query, table: table, limit: 25))
      .filter { $0.table.utf8.elementsEqual(table.utf8) && $0.label.localizedStandardContains(query) }
      .prefix(10)
      .map {
        LookupHit(
          title: $0.label,
          url: try NativeDeepLink(
            destination: NativeDestination(table: table, rowID: $0.id), workspace: binding
          ).url)
      }
  }

  func scheduleRefresh() {
    guard alive, !spotlightTables.isEmpty else { return }
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      await self?.refreshSpotlight()
    }
  }

  func refreshSpotlight() async {
    guard alive, !busy else { return }
    busy = true
    defer { busy = false }
    do { try await reindex() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }

  /// Explicit access removal: forget the workspace's searchable titles and choices.
  func removeAll() async throws {
    refreshTask?.cancel()
    try await spotlight?.remove(domains: [Self.domain(workspaceID)])
    try save(spotlightTables: [], lookupTable: .some(nil), dailySource: .some(nil))
    spotlightTables = []
    lookupTable = nil
    dailySource = nil
  }

  /// Closing keeps indexed titles; they open through the ordinary guarded link flow.
  func cancel() {
    alive = false
    refreshTask?.cancel()
  }

  private func reindex() async throws {
    guard let spotlight else { return }
    let catalog = try await workspace.catalog()
    for table in spotlightTables {
      try Task.checkCancellation()
      let display =
        catalog.tables.first { $0["id"]?.text.utf8.elementsEqual(table.utf8) == true }?["display"]?
        .text.nonempty ?? "id"
      var items: [SpotlightItem] = []
      // ponytail: first 5,000 active rows per table; page by FTS or a cursor if tables grow past it.
      while items.count < 5000 {
        let page = try await workspace.rows(table: table, offset: items.count)
        for row in page {
          guard let id = row.record["id"]?.text, let title = row.record[display]?.text.nonempty
          else { continue }
          let url = try NativeDeepLink(
            destination: NativeDestination(table: table, rowID: id), workspace: binding
          ).url
          items.append(SpotlightItem(id: url.absoluteString, title: String(title.prefix(256))))
        }
        if page.count < 100 { break }
      }
      try Task.checkCancellation()
      try await spotlight.replace(domain: spotlightDomain(table: table), items: items)
    }
  }

  private func save(
    spotlightTables: [String]? = nil, lookupTable: String?? = nil,
    dailySource: NativeWidgetSelection?? = nil
  ) throws {
    if unreadable, FileManager.default.fileExists(atPath: preferencesURL.path) {
      try FileManager.default.moveItem(
        at: preferencesURL,
        to: preferencesURL.appendingPathExtension("unread-" + UUID().uuidString))
      unreadable = false
    }
    let data = try JSONEncoder().encode(
      Preferences(
        version: 1, workspaceID: workspaceID,
        spotlightTables: spotlightTables ?? self.spotlightTables,
        lookupTable: lookupTable ?? self.lookupTable,
        dailySource: dailySource ?? self.dailySource))
    try FileManager.default.createDirectory(
      at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: preferencesURL, options: .atomic)
    error = nil
  }

  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
  private static func domain(_ workspaceID: String) -> String { "iris." + hash(workspaceID) }
  private static var failure: WorkspaceError {
    WorkspaceError(message: "Search and Shortcuts settings are unavailable.", violations: [])
  }
}

#if canImport(CoreSpotlight)
  /// Titles-only items in a protected index; each opens its row via the deep-link banner.
  @MainActor final class CoreSpotlightIndex: SpotlightIndexing {
    #if os(iOS)
      private let index = CSSearchableIndex(name: "Iris", protectionClass: .complete)
    #else
      private let index = CSSearchableIndex(name: "Iris")
    #endif

    /// One batch: a refresh interrupted by relaunch or termination keeps the previous
    /// titles instead of leaving the table's domain empty.
    func replace(domain: String, items: [SpotlightItem]) async throws {
      index.beginBatch()
      // Inside a batch, operations commit at endBatch; their own completions are not needed.
      index.deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: nil)
      if !items.isEmpty {
        index.indexSearchableItems(
          items.map {
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = $0.title
            return CSSearchableItem(
              uniqueIdentifier: $0.id, domainIdentifier: domain, attributeSet: attributes)
          }, completionHandler: nil)
      }
      try await index.endBatch(withClientState: Data())
    }

    func remove(domains: [String]) async throws {
      guard !domains.isEmpty else { return }
      try await index.deleteSearchableItems(withDomainIdentifiers: domains)
    }
  }
#endif
