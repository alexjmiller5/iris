import Foundation

struct NativeDestination: Codable, Hashable, Sendable {
  let table: String
  let viewID: String?
  let rowID: String?
  let state: String?

  init(table: String, viewID: String? = nil, rowID: String? = nil, state: String? = nil) {
    self.table = table
    self.viewID = viewID
    self.rowID = rowID
    self.state = state
  }

  var identity: [Data?] {
    [Data(table.utf8), viewID.map { Data($0.utf8) }, rowID.map { Data($0.utf8) }] + (state.map { [Data($0.utf8)] } ?? [])
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
  func hash(into hasher: inout Hasher) { hasher.combine(identity) }

  private enum CodingKeys: String, CodingKey {
    case table
    case viewID = "view"
    case rowID = "row"
    case state
  }
}

struct NativeResolvedDestination: Sendable {
  let destination: NativeDestination
  let catalog: WorkspaceCatalog
  let view: CoreSavedViewRecord?
  let row: WorkspaceRow?
  var defaultNotice: String? = nil
  var definition: CoreSavedViewDefinition? = nil
  var label: String { row?.label ?? view?.name ?? destination.table }
  var isTrashed: Bool {
    guard let deleted = row?.record["deleted_at"] else { return false }
    return deleted != .null
  }
}

@MainActor
struct NativeDestinationResolver {
  private let catalog: () async throws -> WorkspaceCatalog
  private let listViews: (String) async throws -> CoreSavedViewList
  private let preferred: ((String) async throws -> CoreViewDefault)?
  private let resolveDefinition: ((String, WorkspaceRecord) async throws -> CoreResolvedViewDefinition)?
  private let rows: (CoreView) async throws -> [WorkspaceRow]

  init(workspace: NativeWorkspace) {
    self.init(
      catalog: workspace.catalog, listViews: workspace.listViews, rows: workspace.rows,
      preferred: workspace.getViewDefault, resolveDefinition: workspace.resolveViewDefinition)
  }

  init(
    catalog: @escaping () async throws -> WorkspaceCatalog,
    listViews: @escaping (String) async throws -> CoreSavedViewList,
    rows: @escaping (CoreView) async throws -> [WorkspaceRow],
    preferred: ((String) async throws -> CoreViewDefault)? = nil,
    resolveDefinition: ((String, WorkspaceRecord) async throws -> CoreResolvedViewDefinition)? = nil
  ) {
    self.catalog = catalog
    self.listViews = listViews
    self.rows = rows
    self.preferred = preferred
    self.resolveDefinition = resolveDefinition
  }

  func resolve(_ destination: NativeDestination, isCurrent: () -> Bool) async throws
    -> NativeResolvedDestination
  {
    func checkCurrent() throws {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
    }
    do {
      try checkCurrent()
      let catalog = try await catalog()
      try checkCurrent()
      guard catalog.tables.contains(where: { $0["id"] == .string(destination.table) }) else {
        throw WorkspaceError(message: "Table is no longer available", violations: [])
      }
      var view: CoreSavedViewRecord?
      if let viewID = destination.viewID {
        let listed = try await listViews(destination.table)
        try checkCurrent()
        guard let found = listed.views.first(where: { Data($0.id.utf8) == Data(viewID.utf8) }),
          found.tbl == destination.table, found.deletedAt == nil,
          found.unavailable == nil, found.definition != nil, found.view != nil
        else {
          let reason = listed.views.first(where: { Data($0.id.utf8) == Data(viewID.utf8) })?
            .unavailable
          throw WorkspaceError(
            message: reason ?? listed.unavailable ?? "Saved view is no longer available",
            violations: [])
        }
        view = found
      }
      var defaultNotice: String?
      if destination.viewID == nil, destination.rowID == nil, destination.state == nil, let preferred {
        let selection = try await preferred(destination.table)
        try checkCurrent()
        view = selection.view
        defaultNotice = selection.unavailable
      }
      var transient: CoreSavedViewDefinition?
      if let state = destination.state {
        var definition = try NativeDeepLink.viewState(state)
        if let actions = view?.definition?.actions {
          definition["actions"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(actions))
        }
        guard let resolveDefinition else { throw WorkspaceError(message: "View settings are unavailable.", violations: []) }
        transient = try await resolveDefinition(destination.table, definition).definition
        try checkCurrent()
      }
      var row: WorkspaceRow?
      if let rowID = destination.rowID {
        let firstTrash = transient?.trash ?? view?.definition?.trash ?? false
        for trash in [firstTrash, !firstTrash] {
          let found = try await rows(
            CoreView(
              table: destination.table,
              filters: [CoreFilter(column: "id", op: .eq, value: .string(rowID))], limit: 1,
              trash: trash))
          try checkCurrent()
          if let first = found.first, Data(first.id.utf8) == Data(rowID.utf8) {
            row = first
            break
          }
        }
        guard row != nil else {
          throw WorkspaceError(message: "Record is no longer available", violations: [])
        }
      }
      return NativeResolvedDestination(
        destination: destination, catalog: catalog, view: view, row: row,
        defaultNotice: defaultNotice, definition: transient)
    } catch {
      try checkCurrent()
      throw error
    }
  }
}
