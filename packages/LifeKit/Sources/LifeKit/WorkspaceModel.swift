import CryptoKit
import Foundation
import Observation

struct WorkspaceEditingContext {
  let workspace: NativeWorkspace
  let table: String
  let draftStore: EditorDraftStore?
}

struct ReplicaDownloadContext {
  let workspace: NativeWorkspace
  let endpoint: String
  let generation: Int
}

@Observable @MainActor
final class WorkspaceModel {
  var client: NativeWorkspace? {
    didSet {
      if oldValue !== client {
        linkBinding = nil
        linkIdentityStore = nil
        linkError = nil
        recents?.cancel()
        recents = nil
        workspaceGeneration += 1
        undoAction = nil
        undoing = false
        writingRecord = false
        syncing = false
        resetView()
      }
    }
  }
  private(set) var workspaceGeneration = 0
  private(set) var linkBinding: NativeWorkspaceBinding?
  private(set) var linkError: String?
  private var linkIdentityStore: NativeLinkIdentityStore?
  var canCopyLink: Bool {
    client != nil && !loading && !writingRecord && !undoing && !savingView
      && (linkBinding != nil || linkIdentityStore != nil)
  }

  func linkURL(for destination: NativeDestination, context: WorkspaceEditingContext?) throws -> URL
  {
    guard let context, context.workspace === client,
      table.map({ Data($0.utf8) }) == Data(context.table.utf8),
      Data(destination.table.utf8) == Data(context.table.utf8)
    else {
      throw WorkspaceError(message: "The workspace changed. Copy the link again.", violations: [])
    }
    try requireNavigationReady(workspace: context.workspace, generation: workspaceGeneration)
    guard !loading else {
      throw WorkspaceError(message: "Wait for the workspace to open.", violations: [])
    }
    do {
      if let linkIdentityStore { linkBinding = try linkIdentityStore.create() }
      let url = try NativeDeepLink(destination: destination, workspace: linkBinding).url
      linkError = nil
      return url
    } catch {
      linkError = error.localizedDescription
      throw error
    }
  }

  func linkedDestination(_ link: NativeDeepLink) throws -> NativeDestination {
    guard let client, !loading else {
      throw WorkspaceError(message: "Open the workspace that this link belongs to.", violations: [])
    }
    try requireNavigationReady(workspace: client, generation: workspaceGeneration)
    do {
      // Re-read preferences and the opened file stamp. Incoming URLs never create identity.
      if let linkIdentityStore { linkBinding = try linkIdentityStore.load() }
      let destination = try link.destination(matching: linkBinding)
      linkError = nil
      return destination
    } catch {
      linkError = error.localizedDescription
      throw error
    }
  }
  var catalog: WorkspaceCatalog?
  var table: String? {
    didSet { if oldValue != table { resetView() } }
  }
  var rows: [WorkspaceRow] = []
  var search = ""
  var trash = false
  private(set) var sortRules: [CoreSort] = []
  var sortColumn: String {
    get { sortRules.first?.column ?? "" }
    set {
      if newValue.isEmpty {
        sortRules = []
      } else {
        sortRules =
          [CoreSort(column: newValue, direction: sortRules.first?.direction ?? .asc)]
          + sortRules.dropFirst().filter { $0.column != newValue }
      }
    }
  }
  var sortAscending: Bool {
    get { sortRules.first?.direction != .desc }
    set { if !sortRules.isEmpty { sortRules[0].direction = newValue ? .asc : .desc } }
  }
  var filters: [WorkspaceFilter] = []
  private(set) var savedViews: [CoreSavedViewRecord] = []
  private(set) var appliedView: CoreSavedViewRecord?
  private(set) var savedViewsUnavailable: String?
  private(set) var savingView = false
  private var viewGeneration = 0
  private var viewsRequest = 0
  private(set) var writeability: CoreWriteability?
  private(set) var viewsWriteability: CoreWriteability?
  private var writeabilityError: String?
  private var writeabilityRequest = 0
  var loading = false
  var error: String?
  var location = ""
  var canLoadMore = false
  var syncing = false
  var syncResult: WorkspaceSyncResult?
  var syncStatus: WorkspaceSyncStatus?
  private(set) var undoAction: CoreUndoAction?
  private(set) var undoing = false
  private var writingRecord = false

  @discardableResult
  func undo(_ action: CoreUndoAction, context: WorkspaceEditingContext?) async throws
    -> WorkspaceRecord
  {
    guard let context, context.workspace === client, context.table == table,
      action == undoAction, !undoing, !writingRecord, !savingView
    else {
      throw WorkspaceError(
        message:
          "This saved change is no longer ready to undo. Reopen it after the current operation finishes.",
        violations: [])
    }
    let generation = workspaceGeneration
    undoing = true
    defer { if generation == workspaceGeneration { undoing = false } }
    do {
      let receipt = try await context.workspace.undo(receiptID: action.receiptId)
      guard context.workspace === client, generation == workspaceGeneration,
        context.table == table
      else {
        throw WorkspaceError(
          message:
            "The workspace changed while undoing. Reopen the record to review its saved state.",
          violations: [])
      }
      undoAction = nil
      await reload()
      guard context.workspace === client, generation == workspaceGeneration, context.table == table
      else {
        throw WorkspaceError(
          message: "The workspace changed while refreshing Undo. Reopen the record.", violations: []
        )
      }
      return receipt
    } catch {
      if context.workspace === client, generation == workspaceGeneration {
        await reload()
      }
      throw error
    }
  }
  var connection: HubCredentials?
  var isReplica = false
  var groups: [String: String] = [:]
  private(set) var recoverableDrafts: [StoredEditorDraft] = []
  private(set) var recents: NativeRecentsModel?
  private var draftStore: EditorDraftStore?
  let services = HubServicesModel()
  private var groupsURL: URL?
  private var transport: HubTransport?
  private var revision = 0
  private var scopedURL: URL?
  private let resolveLocalURL: @MainActor () throws -> URL
  private let makeTransport: @MainActor (HubCredentials) throws -> HubTransport
  private let credentialStore: any HubCredentialStorage

  private(set) var downloadPreferences = ReplicaPreferences()
  private var downloadStore: ReplicaPreferenceStore?
  var downloadContext: ReplicaDownloadContext? {
    guard isReplica, let client, let transport else { return nil }
    return ReplicaDownloadContext(
      workspace: client, endpoint: transport.endpoint, generation: workspaceGeneration)
  }
  var skippedTables: [String] { isReplica ? syncStatus?.skippedTables ?? [] : [] }

  var partialTableNotice: String? {
    guard isReplica, let table, skippedTables.contains(table) else { return nil }
    if downloadPreferences.tables[table] == false {
      return
        "This table is excluded from future sync. Existing local records are kept and may be incomplete."
    }
    return downloadPreferences.tables[table] == true
      ? "This table is included in the next sync. Its local records may still be incomplete."
      : "This table was not downloaded in the last sync. Its local records may be incomplete."
  }

  func saveDownloads(_ preferences: ReplicaPreferences, context: ReplicaDownloadContext) throws {
    guard isReplica, context.workspace === client, context.endpoint == transport?.endpoint,
      context.generation == workspaceGeneration, let downloadStore
    else {
      throw WorkspaceError(
        message: "The workspace changed. Reopen Downloads before saving.", violations: [])
    }
    guard !syncing else {
      throw WorkspaceError(
        message: "Wait for sync to finish before changing download settings.", violations: [])
    }
    try downloadStore.save(preferences)
    downloadPreferences = preferences
  }

  init(
    localURL: @escaping @MainActor () throws -> URL = WorkspaceModel.localURL,
    makeTransport: @escaping @MainActor (HubCredentials) throws -> HubTransport = {
      try HubTransport(endpoint: $0.endpoint, token: $0.token)
    },
    credentialStore: any HubCredentialStorage = HubCredentialStore()
  ) {
    resolveLocalURL = localURL
    self.makeTransport = makeTransport
    self.credentialStore = credentialStore
  }

  var queryKey: [String] {
    [table ?? "", search, String(trash), appliedView?.id ?? "", String(viewGeneration)]
      + sortRules.flatMap { [$0.column, $0.direction.rawValue] }
      + filters.flatMap { [$0.column, $0.operation.rawValue, $0.value] }
  }

  private func resetView() {
    invalidateWriteability()
    revision += 1
    viewGeneration += 1
    viewsRequest += 1
    savedViews = []
    appliedView = nil
    savedViewsUnavailable = nil
    savingView = false
    search = ""
    trash = false
    sortColumn = ""
    sortAscending = true
    filters = []
    rows = []
    canLoadMore = false
    loading = false
  }

  func applyViewOptions(
    sortColumn: String, ascending: Bool, filters: [WorkspaceFilter],
    context: WorkspaceEditingContext?
  ) throws {
    guard let context, context.workspace === client, context.table == table else {
      throw WorkspaceError(
        message: "The workspace or table changed. Reopen view options.", violations: [])
    }
    let fields = properties.map(CatalogField.init)
    for filter in filters {
      _ = try filter.coreFilter(field: fields.first { $0.id == filter.column })
    }
    self.sortColumn = sortColumn
    sortAscending = ascending
    self.filters = filters
  }

  var editingContext: WorkspaceEditingContext? {
    guard let client, let table else { return nil }
    return WorkspaceEditingContext(workspace: client, table: table, draftStore: draftStore)
  }
  func refreshedRecordContext(
    _ resolved: NativeResolvedDestination, workspace: NativeWorkspace, generation: Int
  ) throws -> WorkspaceEditingContext {
    try requireNavigationReady(workspace: workspace, generation: generation)
    guard resolved.destination.table == table, resolved.row != nil,
      resolved.catalog.tables.contains(where: { $0["id"] == .string(resolved.destination.table) })
    else {
      throw WorkspaceError(message: "The table changed. Open the record again.", violations: [])
    }
    catalog = resolved.catalog
    return WorkspaceEditingContext(
      workspace: workspace, table: resolved.destination.table, draftStore: draftStore)
  }
  var tables: [WorkspaceRecord] { catalog?.tables ?? [] }
  var properties: [WorkspaceRecord] {
    Self.properties(in: catalog, table: table)
  }
  private static func properties(in catalog: WorkspaceCatalog?, table: String?) -> [WorkspaceRecord]
  {
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
      && !properties.isEmpty && writeability?.writable == true
  }

  var editingUnavailable: String? {
    guard client != nil, table != nil else { return nil }
    return writeabilityError ?? writeability?.reason?.message
      ?? (writeability == nil ? "Checking editing availability…" : nil)
  }

  var savedViewEditingUnavailable: String? {
    writeabilityError ?? viewsWriteability?.reason?.message
      ?? (viewsWriteability == nil ? "Checking editing availability…" : nil)
  }

  private func invalidateWriteability() {
    writeabilityRequest += 1
    writeability = nil
    viewsWriteability = nil
    writeabilityError = nil
  }

  func refreshWriteability() async {
    guard let client, let table else {
      invalidateWriteability()
      return
    }
    writeabilityRequest += 1
    let request = writeabilityRequest
    let generation = workspaceGeneration
    do {
      let current = try await client.writeability(table: table)
      let views = table == "views" ? current : try await client.writeability(table: "views")
      guard self.client === client, self.table == table,
        generation == workspaceGeneration, request == writeabilityRequest
      else { return }
      writeability = current
      viewsWriteability = views
      writeabilityError = nil
    } catch {
      guard self.client === client, self.table == table,
        generation == workspaceGeneration, request == writeabilityRequest
      else { return }
      writeability = nil
      viewsWriteability = nil
      writeabilityError = error.localizedDescription
    }
  }

  var visibleRecordColumns: [String]? { appliedView?.definition?.columns }

  func currentViewDefinition() throws -> CoreSavedViewDefinition {
    var definition = appliedView?.definition ?? CoreSavedViewDefinition(version: 1)
    let fields = properties.map(CatalogField.init)
    let currentFilters = try filters.map { filter in
      try filter.coreFilter(field: fields.first { $0.id == filter.column })
    }
    if currentFilters != (definition.filters ?? []) { definition.filters = currentFilters }
    if sortRules != (definition.sort ?? []) { definition.sort = sortRules }
    if search != (definition.search ?? "") { definition.search = search }
    if trash != (definition.trash ?? false) { definition.trash = trash }
    return definition
  }

  var viewModified: Bool {
    guard let appliedView else { return false }
    return (try? currentViewDefinition()) != appliedView.definition
  }

  private func requireViewContext(_ context: WorkspaceEditingContext?, generation: Int? = nil)
    throws
    -> WorkspaceEditingContext
  {
    guard let context, context.workspace === client, context.table == table,
      generation == nil || generation == workspaceGeneration
    else {
      throw WorkspaceError(
        message: "The workspace or table changed. Reopen saved views.", violations: [])
    }
    return context
  }

  func refreshSavedViews(context: WorkspaceEditingContext?) async throws {
    let context = try requireViewContext(context)
    await refreshWriteability()
    _ = try requireViewContext(context)
    viewsRequest += 1
    let request = viewsRequest
    let generation = viewGeneration
    let workspace = workspaceGeneration
    let result = try await context.workspace.listViews(table: context.table)
    _ = try requireViewContext(context, generation: workspace)
    guard request == viewsRequest, generation == viewGeneration else { return }
    savedViews = result.views
    savedViewsUnavailable = result.unavailable
    // The list is current; an applied view retains the revision the user opened.
  }

  func applySavedView(_ saved: CoreSavedViewRecord?, context: WorkspaceEditingContext?) throws {
    let context = try requireViewContext(context)
    guard !savingView, !undoing else {
      throw WorkspaceError(message: "Wait for the saved view to finish saving.", violations: [])
    }
    if let saved {
      guard saved.tbl == context.table, saved.deletedAt == nil,
        saved.unavailable == nil, let definition = saved.definition, saved.view != nil
      else {
        throw WorkspaceError(
          message: saved.unavailable ?? "This saved view is unavailable.", violations: [])
      }
      appliedView = saved
      search = definition.search ?? ""
      trash = definition.trash ?? false
      sortRules = definition.sort ?? []
      let fields = properties.map(CatalogField.init)
      filters = (definition.filters ?? []).map { filter in
        WorkspaceFilter(filter, field: fields.first { $0.id == filter.column })
      }
    } else {
      appliedView = nil
      search = ""
      trash = false
      sortRules = []
      filters = []
    }
    viewGeneration += 1
  }

  func saveCurrentView(name: String, update: Bool, context: WorkspaceEditingContext?) async throws {
    let context = try requireViewContext(context)
    guard !savingView, !undoing else {
      throw WorkspaceError(
        message: "A saved view operation is already in progress.", violations: [])
    }
    let selected = appliedView
    if update && (selected == nil || selected?.updatedAt == nil) {
      throw WorkspaceError(message: "Reopen this saved view before updating it.", violations: [])
    }
    let args = CoreSaveViewArgs(
      table: context.table, name: name,
      definition: try currentViewDefinition(), id: update ? selected?.id : nil,
      expectedUpdatedAt: update ? selected?.updatedAt : nil)
    let generation = viewGeneration
    let workspace = workspaceGeneration
    viewsRequest += 1
    savingView = true
    defer { if generation == viewGeneration { savingView = false } }
    let saved = try await context.workspace.saveView(args)
    _ = try requireViewContext(context, generation: workspace)
    guard generation == viewGeneration else {
      throw WorkspaceError(
        message: "The selected view changed while saving. Reopen saved views.", violations: [])
    }
    appliedView = saved
    savedViews.removeAll { $0.byteExactID == saved.byteExactID }
    savedViews.append(saved)
    savedViews.sort {
      $0.name == $1.name
        ? $0.byteExactID.lexicographicallyPrecedes($1.byteExactID) : $0.name < $1.name
    }
    await reload()
  }

  func deleteSavedView(_ saved: CoreSavedViewRecord, context: WorkspaceEditingContext?) async throws
  {
    let context = try requireViewContext(context)
    guard !savingView, !undoing, saved.tbl == context.table, let updatedAt = saved.updatedAt else {
      throw WorkspaceError(message: "Reopen this saved view before deleting it.", violations: [])
    }
    let generation = viewGeneration
    let workspace = workspaceGeneration
    viewsRequest += 1
    savingView = true
    defer { if generation == viewGeneration { savingView = false } }
    _ = try await context.workspace.deleteView(
      CoreDeleteViewArgs(id: saved.id, expectedUpdatedAt: updatedAt))
    _ = try requireViewContext(context, generation: workspace)
    guard generation == viewGeneration else {
      throw WorkspaceError(
        message: "The selected view changed while deleting. Reopen saved views.", violations: [])
    }
    savingView = false
    savedViews.removeAll { $0.byteExactID == saved.byteExactID }
    if appliedView?.byteExactID == saved.byteExactID { try applySavedView(nil, context: context) }
    await reload()
  }

  func requireNavigationReady(workspace: NativeWorkspace, generation: Int) throws {
    guard client === workspace, workspaceGeneration == generation else {
      throw WorkspaceError(
        message: "The workspace changed. Open the destination again.", violations: [])
    }
    guard !writingRecord, !undoing, !savingView else {
      throw WorkspaceError(
        message: "Wait for the current operation to finish before navigating.", violations: [])
    }
  }

  func makeRejectionInbox() -> RejectionInboxModel? {
    guard let client else { return nil }
    let generation = workspaceGeneration
    return RejectionInboxModel(
      readStatus: client.status, readPage: client.rejections,
      isCurrent: { [weak self] in
        self?.client === client && self?.workspaceGeneration == generation
      })
  }

  func prepareRejectionReview(
    _ entry: CoreRejectedEdit, workspace: NativeWorkspace, generation: Int,
    isCurrent: () -> Bool = { true }
  ) async throws -> PreparedRejectionReview {
    let query = queryKey.map { Data($0.utf8) }
    func current() -> Bool {
      isCurrent() && client === workspace && workspaceGeneration == generation
        && queryKey.map { Data($0.utf8) } == query && !Task.isCancelled
    }
    func check() throws {
      guard current() else { throw CancellationError() }
      try requireNavigationReady(workspace: workspace, generation: generation)
    }
    do {
      try check()
      let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
        NativeDestination(table: entry.table, rowID: entry.rowID), isCurrent: current)
      try check()
      let permission = try await workspace.writeability(table: entry.table)
      try check()
      guard permission.writable else {
        throw WorkspaceError(
          message: permission.reason?.message ?? "This table cannot be edited on this device.",
          violations: [])
      }
      let context = WorkspaceEditingContext(
        workspace: workspace, table: entry.table, draftStore: draftStore)
      let editor = RecordEditorModel(
        properties: Self.properties(in: resolved.catalog, table: entry.table),
        original: resolved.row?.record, table: entry.table, store: draftStore
      ) { patch, baseline in
        try await self.save(patch, original: baseline, context: context)
      }
      try editor.installRejectedDraft(submitted: entry.submitted)
      return PreparedRejectionReview(
        resolved: resolved, context: context, editor: editor,
        generation: generation, sourceQuery: query)
    } catch {
      try check()
      throw error
    }
  }

  func activateRejectionReview(
    _ prepared: PreparedRejectionReview, isCurrent: () -> Bool = { true }
  ) throws {
    guard isCurrent(), !Task.isCancelled,
      queryKey.map({ Data($0.utf8) }) == prepared.sourceQuery
    else { throw CancellationError() }
    _ = try activateDestination(
      prepared.resolved, workspace: prepared.context.workspace,
      generation: prepared.generation)
  }

  func activateDestination(
    _ resolved: NativeResolvedDestination, workspace: NativeWorkspace, generation: Int
  ) throws -> WorkspaceEditingContext {
    try requireNavigationReady(workspace: workspace, generation: generation)
    let target = resolved.destination.table
    guard resolved.catalog.tables.contains(where: { $0["id"] == .string(target) }) else {
      throw WorkspaceError(message: "Table is no longer available.", violations: [])
    }
    // Resolution validates the destination. Recheck the host before installing
    // it synchronously, including resetting settings for the same table.
    catalog = resolved.catalog
    if table == target { resetView() } else { table = target }
    let context = WorkspaceEditingContext(
      workspace: workspace, table: target, draftStore: draftStore)
    try applySavedView(resolved.view, context: context)
    if resolved.row != nil { trash = resolved.isTrashed }
    return context
  }

  func makeCommandPalette() -> QuickFindCoordinator? {
    guard let client, let search = makeQuickFind() else { return nil }
    let generation = workspaceGeneration
    let current = { [weak self] in
      self?.client === client && self?.workspaceGeneration == generation
    }
    let resolver = NativeDestinationResolver(workspace: client)
    return QuickFindCoordinator(
      search: search,
      metadata: NativePaletteModel(workspace: client, isCurrent: current),
      resolve: { destination, isCurrent in
        try await resolver.resolve(destination, isCurrent: isCurrent)
      }, isCurrent: current)
  }

  func makeQuickFind() -> QuickFindModel? {
    guard let client else { return nil }
    let generation = workspaceGeneration
    return QuickFindModel(
      search: client.search, read: client.rows,
      isCurrent: { [weak self] in
        self?.client === client && self?.workspaceGeneration == generation
      })
  }

  func makeOnlineBrowser() -> OnlineBrowseModel? {
    guard isReplica, let client, let transport, let table else { return nil }
    let workspace = workspaceGeneration
    let view = viewGeneration
    return OnlineBrowseModel(
      table: table,
      load: { cursor in
        try await client.remoteRows(using: transport, table: table, cursor: cursor)
      },
      read: { id in try await client.remoteRow(using: transport, table: table, id: id) },
      isCurrent: { [weak self] in
        self?.isReplica == true && self?.client === client
          && self?.transport?.endpoint == transport.endpoint && self?.table == table
          && self?.workspaceGeneration == workspace && self?.viewGeneration == view
      })
  }

  func activateSearchTable(_ table: String, workspace: NativeWorkspace, generation: Int) throws
    -> WorkspaceEditingContext
  {
    guard client === workspace, workspaceGeneration == generation,
      tables.contains(where: { $0["id"]?.text == table })
    else {
      throw WorkspaceError(
        message: "The workspace changed. Search again to open the record.", violations: [])
    }
    self.table = table
    trash = false
    return WorkspaceEditingContext(workspace: workspace, table: table, draftStore: draftStore)
  }

  func incomingReferencesIdentity(context: WorkspaceEditingContext?, row: WorkspaceRecord?)
    -> IncomingReferencesIdentity?
  {
    guard let context, context.workspace === client, context.table == table,
      let rowID = row?["id"]?.text.nonempty
    else { return nil }
    return IncomingReferencesIdentity(
      workspaceGeneration: workspaceGeneration, table: context.table, rowID: rowID,
      catalog: catalog, skippedTables: Set(skippedTables))
  }

  func makeIncomingReferences(
    context: WorkspaceEditingContext?, row: WorkspaceRecord?,
    isCurrent: @escaping () -> Bool = { true }
  ) -> IncomingReferencesModel? {
    guard let context, let identity = incomingReferencesIdentity(context: context, row: row) else {
      return nil
    }
    let selection = viewGeneration
    return IncomingReferencesModel(
      table: identity.table, rowID: identity.rowID,
      readSources: { try await context.workspace.referenceSources($0) },
      readPage: { try await context.workspace.referencedBy($0) },
      isCurrent: { [weak self] in
        self?.viewGeneration == selection
          && self?.incomingReferencesIdentity(context: context, row: row) == identity && isCurrent()
      })
  }

  func makeReferenceNavigation(
    editor: RecordEditorModel, context: WorkspaceEditingContext,
    isCurrent: @escaping () -> Bool = { true },
    onOpen: @escaping (ReferenceDestination) -> Void = { _ in }
  ) -> ReferenceNavigationModel {
    let generation = workspaceGeneration
    let selection = viewGeneration
    return ReferenceNavigationModel(
      editor: editor,
      read: { [weak self] view in
        guard self?.tables.contains(where: { $0["id"]?.text == view.table }) == true else {
          throw WorkspaceError(
            message: "The related table is not available on this device.", violations: [])
        }
        return try await context.workspace.rows(view: view)
      },
      isCurrent: { [weak self] in
        self?.client === context.workspace && self?.workspaceGeneration == generation
          && self?.viewGeneration == selection && self?.table == context.table && isCurrent()
      }, onOpen: onOpen)
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
    workspaceGeneration += 1
    loading = true
    error = nil
    transport = nil
    services.configure(workspace: nil, transport: nil)
    isReplica = false
    downloadStore = nil
    downloadPreferences = ReplicaPreferences()
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
        let file = try url ?? resolveLocalURL()
        if url != nil, file.startAccessingSecurityScopedResource() { scopedURL = file }
        path = file.path
        seed = url == nil && !FileManager.default.fileExists(atPath: path)
      }
      try loadGroups(workspace: demo ? nil : path)
      try prepareDrafts(path: demo ? nil : path)
      let recentStore =
        demo
        ? nil
        : NativeRecentsStore(
          root: try resolveLocalURL().deletingLastPathComponent(),
          workspace: URL(fileURLWithPath: path))
      let workspace = try NativeWorkspace(path: path)
      do {
        if seed { try await workspace.createSample() }
        if !demo, url == nil { try await workspace.prepareLocalViews() }
        catalog = try await workspace.catalog()
      } catch {
        try? await workspace.close()
        throw error
      }
      client = workspace
      if !demo {
        do {
          linkIdentityStore = try NativeLinkIdentityStore(
            root: resolveLocalURL().deletingLastPathComponent(),
            workspace: URL(fileURLWithPath: path)
          ).retainingOpenedFile()
          linkBinding = try linkIdentityStore?.load()
        } catch { linkError = error.localizedDescription }
      }
      configureRecents(store: recentStore)
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
    revision += 1
    guard let client, let table else {
      rows = []
      loading = false
      return
    }
    let request = revision
    let query = queryKey
    loading = true
    error = nil
    await refreshWriteability()
    do {
      let definition = try currentViewDefinition()
      let view = CoreView(
        table: table,
        filters: definition.filters, sort: definition.sort,
        limit: 100, offset: more ? rows.count : 0, trash: trash, search: search)
      let result = try await client.rows(view: view)
      let status = isReplica ? try await client.status() : nil
      let undo = try await client.undoStatus()
      guard request == revision, self.client === client, query == queryKey else { return }
      syncStatus = status
      undoAction = undo.action
      rows = more ? rows + result : result
      canLoadMore = result.count == 100
    } catch {
      guard request == revision, self.client === client, query == queryKey else { return }
      self.error = error.localizedDescription
      if !more { rows = [] }
    }
    loading = false
  }

  @discardableResult
  func save(_ patch: WorkspaceRecord, original: WorkspaceRecord?, context: WorkspaceEditingContext?)
    async throws -> WorkspaceRecord
  {
    guard let client, let table else {
      throw WorkspaceError(message: "Open a workspace before saving.", violations: [])
    }
    guard let context, context.workspace === client, context.table == table else {
      throw WorkspaceError(
        message: "The workspace or table changed. Reopen the record before saving.", violations: [])
    }
    guard !undoing, !writingRecord else {
      throw WorkspaceError(
        message: "Wait for the current record operation to finish.", violations: [])
    }
    let generation = workspaceGeneration
    writingRecord = true
    defer { if generation == workspaceGeneration { writingRecord = false } }
    let receipt = try await context.workspace.write(
      table: context.table, patch: patch, expectedUpdatedAt: original?["updated_at"]?.text)
    await reload()
    return receipt
  }

  private func prepareDrafts(path: String?) throws {
    draftStore = nil
    recoverableDrafts = []
    guard let path else { return }
    let root = try resolveLocalURL().deletingLastPathComponent().appendingPathComponent("drafts")
    draftStore = EditorDraftStore(root: root, workspace: URL(fileURLWithPath: path))
    refreshDrafts()
  }

  private func configureRecents(store: NativeRecentsStore?) {
    guard let client else { return }
    let resolver = NativeDestinationResolver(workspace: client)
    // Forgetting a credential keeps this database open. Its local history
    // remains usable; replacing/closing the client cancels the old model.
    let current = { [weak self] in self?.client === client }
    recents = NativeRecentsModel(
      store: store,
      resolve: { try await resolver.resolve($0, isCurrent: current) }, isCurrent: current)
  }

  func refreshDrafts() {
    do { recoverableDrafts = try draftStore?.all() ?? [] } catch {
      self.error = "Saved drafts could not be opened. They have been kept."
    }
  }

  func recoveryRecord(_ saved: StoredEditorDraft, context: WorkspaceEditingContext) async throws
    -> WorkspaceRecord?
  {
    guard context.workspace === client, context.table == table, saved.table == context.table else {
      throw WorkspaceError(message: "The workspace changed. Open the draft again.", violations: [])
    }
    guard let id = saved.recordID else { return nil }
    for trashed in [false, true] {
      let rows = try await context.workspace.rows(
        view: CoreView(
          table: context.table,
          filters: [CoreFilter(column: "id", op: .eq, value: .string(id))], limit: 1, trash: trashed
        ))
      guard context.workspace === client, context.table == table else {
        throw WorkspaceError(
          message: "The workspace changed. Open the draft again.", violations: [])
      }
      if let row = rows.first { return row.record }
    }
    return nil
  }

  private func loadGroups(workspace: String?) throws {
    groups = [:]
    groupsURL = nil
    guard let workspace else { return }
    let name = SHA256.hash(data: Data(workspace.utf8)).map { String(format: "%02x", $0) }.joined()
    let url = try resolveLocalURL().deletingLastPathComponent().appendingPathComponent(
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
      guard let saved = try credentialStore.load() else { return }
      // An established replica must open even when the hub is unreachable.
      let hub = try makeTransport(saved)
      try await installConnection(saved, hub: hub, remember: false, isCurrent: { true })
      await reload()
      await synchronize()
    } catch { self.error = error.localizedDescription }
  }

  nonisolated static func replicaKey(endpoint: String) -> String {
    SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func replicaURL(root: URL, endpoint: String) -> URL {
    let name = replicaKey(endpoint: endpoint)
    return root.appendingPathComponent("replicas", isDirectory: true).appendingPathComponent(
      name + ".sqlite")
  }

  func connect(
    _ credentials: HubCredentials, remember: Bool = true,
    expectedFingerprint: String? = nil, synchronizeAfter: Bool = true,
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async throws {
    let generation = workspaceGeneration
    let current: @MainActor () -> Bool = {
      self.workspaceGeneration == generation && isCurrent() && !Task.isCancelled
    }
    guard current() else { throw CancellationError() }
    let hub = try makeTransport(credentials)
    let core = try EnrollmentCore()
    let fingerprint = SHA256.hash(data: Data(credentials.token.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let policy = try await core.policy(fingerprint: fingerprint)
    let reply = try await hub.sessionReply(maxResponseBytes: policy.maxResponseBytes)
    let session: CoreSessionInfo
    if let expectedFingerprint {
      let result = try await core.request(
        CoreRequests.EnrollmentPollResult(
          CoreEnrollmentPollArgs(reply: reply, expectedFingerprint: expectedFingerprint)))
      guard result.state == .approved, let approved = result.session else {
        throw WorkspaceError(message: "This device is not approved yet.", violations: [])
      }
      session = approved
    } else {
      guard reply.status == 200 else {
        throw WorkspaceError(
          message: "Device validation returned HTTP \(reply.status).", violations: [])
      }
      session = try await core.request(
        CoreRequests.ValidateDeviceSession(CoreSessionDataArgs(data: reply.data)))
    }
    guard session.replica.allowed else {
      throw WorkspaceError(
        message: session.replica.reason?.message ?? "This credential cannot sync a replica.",
        violations: [])
    }
    guard current() else { throw CancellationError() }
    try await installConnection(credentials, hub: hub, remember: remember, isCurrent: current)
    if synchronizeAfter { await synchronize() }
  }

  private func installConnection(
    _ credentials: HubCredentials, hub: HubTransport, remember: Bool,
    isCurrent: @MainActor () -> Bool
  ) async throws {
    let generation = workspaceGeneration
    let canonical = HubCredentials(endpoint: hub.endpoint, token: credentials.token)
    let root = try resolveLocalURL().deletingLastPathComponent()
    let path = Self.replicaURL(root: root, endpoint: hub.endpoint)
    let preferencesStore = ReplicaPreferenceStore(
      root: path.deletingLastPathComponent().appendingPathComponent("downloads"),
      endpoint: hub.endpoint)
    let preferences = try preferencesStore.load()
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let prepared = try NativeWorkspace(path: path.path)
    let nextCatalog: WorkspaceCatalog
    let nextGroups: [String: String]
    let groupsKey = SHA256.hash(data: Data(path.path.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let nextGroupsURL = root.appendingPathComponent("groups-" + groupsKey + ".json")
    do {
      nextCatalog = try await prepared.catalog()
      nextGroups =
        FileManager.default.fileExists(atPath: nextGroupsURL.path)
        ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: nextGroupsURL))
        : [:]
      guard generation == workspaceGeneration, isCurrent(), !Task.isCancelled else {
        throw CancellationError()
      }
      // All fallible preparation precedes the synchronous Keychain+workspace commit.
      if remember { try credentialStore.save(canonical) }
    } catch {
      try? await prepared.close()
      throw error
    }
    let old = client
    services.configure(workspace: nil, transport: nil)
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
    client = prepared
    linkBinding = .replica(canonicalEndpoint: hub.endpoint)
    configureRecents(store: NativeRecentsStore(root: root, workspace: path))
    catalog = nextCatalog
    groups = nextGroups
    groupsURL = nextGroupsURL
    draftStore = EditorDraftStore(root: root.appendingPathComponent("drafts"), workspace: path)
    refreshDrafts()
    transport = hub
    services.configure(workspace: prepared, transport: hub)
    connection = canonical
    downloadStore = preferencesStore
    downloadPreferences = preferences
    syncResult = nil
    syncStatus = nil
    isReplica = true
    location = "Hub workspace · local replica"
    table =
      tables.first(where: { $0["readOnly"] == .bool(false) })?["id"]?.text
      ?? tables.first?["id"]?.text
    rows = []
    search = ""
    trash = false
    if let old { Task { try? await old.close() } }
  }

  func synchronize() async {
    guard let client, let transport, !syncing else { return }
    let generation = workspaceGeneration
    syncing = true
    defer { if client === self.client, generation == workspaceGeneration { syncing = false } }
    invalidateWriteability()
    error = nil
    do {
      let result = try await client.sync(
        using: transport, maxRows: downloadPreferences.maxRows, tables: downloadPreferences.tables)
      guard client === self.client, generation == workspaceGeneration else { return }
      let updatedCatalog = try await client.catalog()
      guard client === self.client, generation == workspaceGeneration else { return }
      syncResult = result
      catalog = updatedCatalog
      if !tables.contains(where: { $0["id"]?.text == table }) {
        table =
          tables.first(where: { $0["readOnly"] == .bool(false) })?["id"]?.text
          ?? tables.first?["id"]?.text
      }
      await reload()
    } catch {
      // Keep the replica and queued edits available offline after a failed request.
      guard client === self.client, generation == workspaceGeneration else { return }
      let cachedCatalog = try? await client.catalog()
      guard client === self.client, generation == workspaceGeneration else { return }
      catalog = cachedCatalog
      if table == nil { table = tables.first?["id"]?.text }
      await reload()
      guard client === self.client, generation == workspaceGeneration else { return }
      self.error = error.localizedDescription
    }
  }

  func forgetConnection() throws {
    try credentialStore.remove()
    workspaceGeneration += 1
    syncing = false
    connection = nil
    transport = nil
    services.configure(workspace: nil, transport: nil)
    isReplica = false
    downloadStore = nil
    downloadPreferences = ReplicaPreferences()
  }

  func close() async {
    workspaceGeneration += 1
    revision += 1
    services.configure(workspace: nil, transport: nil)
    do { try await client?.close() } catch {
      self.error = error.localizedDescription
      return
    }
    client = nil
    transport = nil
    isReplica = false
    downloadStore = nil
    downloadPreferences = ReplicaPreferences()
    syncResult = nil
    syncStatus = nil
    catalog = nil
    rows = []
    draftStore = nil
    recoverableDrafts = []
    scopedURL?.stopAccessingSecurityScopedResource()
    scopedURL = nil
  }
}
