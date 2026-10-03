import Foundation
import Observation

/// Apply this identity to the incoming panel, never to its owning record editor.
struct IncomingReferencesIdentity: Hashable {
  let workspaceGeneration: Int
  let table: String
  let rowID: String
  let catalog: WorkspaceCatalog?
  let skippedTables: Set<String>
  private let exactRowID: Data

  init(workspaceGeneration: Int, table: String, rowID: String,
    catalog: WorkspaceCatalog?, skippedTables: Set<String>
  ) {
    self.workspaceGeneration = workspaceGeneration
    self.table = table
    self.rowID = rowID
    self.catalog = catalog
    self.skippedTables = skippedTables
    exactRowID = Data(rowID.utf8)
  }
}

struct IncomingReferenceGroup: Identifiable {
  struct ID: Hashable {
    let table: String
    let column: String
  }
  var id: ID { ID(table: source.table, column: source.column) }
  var source: CoreReferenceSource
  var rows: [WorkspaceRow] = []
  var nextOffset: CoreCount?
  var loaded = false
  var loading = false
  var error: String?
}

@Observable @MainActor
final class IncomingReferencesModel {
  private(set) var groups: [IncomingReferenceGroup] = []
  private(set) var loading = false
  private(set) var error: String?
  private let table: String
  private let rowID: String
  private let readSources: (CoreReferenceSourcesArgs) async throws -> [CoreReferenceSource]
  private let readPage: (CoreReferencedByArgs) async throws -> CoreReferencedByPage
  private let isCurrent: () -> Bool
  private var generation = 0
  private var disposed = false

  init(
    table: String, rowID: String,
    readSources: @escaping (CoreReferenceSourcesArgs) async throws -> [CoreReferenceSource],
    readPage: @escaping (CoreReferencedByArgs) async throws -> CoreReferencedByPage,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.table = table
    self.rowID = rowID
    self.readSources = readSources
    self.readPage = readPage
    self.isCurrent = isCurrent
  }

  private func current(_ version: Int) -> Bool {
    !disposed && generation == version && isCurrent() && !Task.isCancelled
  }

  func refresh() async {
    guard current(generation) else { return }
    generation += 1
    let version = generation
    groups = []
    loading = true
    error = nil
    defer { if version == generation { loading = false } }
    do {
      let sources = try await readSources(CoreReferenceSourcesArgs(table: table))
      guard current(version) else { return }
      groups = sources.map { IncomingReferenceGroup(source: $0) }
    } catch {
      guard current(version) else { return }
      self.error = error.localizedDescription
    }
  }

  func load(_ id: IncomingReferenceGroup.ID, more: Bool = false) async {
    guard current(generation), let index = groups.firstIndex(where: { $0.id == id }) else { return }
    let group = groups[index]
    guard !group.loading,
      more ? group.loaded && group.nextOffset != nil : !group.loaded
    else { return }
    let version = generation
    groups[index].loading = true
    groups[index].error = nil
    defer { if version == generation { groups[index].loading = false } }
    do {
      let page = try await readPage(
        CoreReferencedByArgs(
          table: table, rowId: rowID, sourceTable: id.table, column: id.column,
          limit: 20, offset: more ? group.nextOffset : 0))
      guard current(version) else { return }
      var rows = group.rows
      var positions = Dictionary(
        uniqueKeysWithValues: rows.enumerated().map { ($0.element.byteExactID, $0.offset) })
      for row in page.rows {
        if let position = positions[row.byteExactID] {
          rows[position] = row
        } else {
          positions[row.byteExactID] = rows.count
          rows.append(row)
        }
      }
      groups[index].source = page.source
      groups[index].rows = rows
      groups[index].nextOffset = page.nextOffset
      groups[index].loaded = true
    } catch {
      guard current(version) else { return }
      groups[index].error = error.localizedDescription
    }
  }

  func dispose() {
    disposed = true
    generation += 1
    loading = false
    for index in groups.indices { groups[index].loading = false }
  }
}
