import Foundation
import Observation

struct NativeWidgetSelection: Codable, Identifiable, Sendable {
  let table: String
  let viewID: String?
  var id: String {
    WidgetLibrary.sourceID(workspaceID: "", table: table, viewID: viewID, kind: .list)
  }
}

/// Durable app preferences hold only source identities and an authorization epoch.
/// Regenerable publications never become the authority for enabling a source.
@Observable @MainActor final class NativeWidgetSettings {
  private(set) var selections: [NativeWidgetSelection] = []
  private(set) var busy = false
  private(set) var error: String?
  private(set) var unreadable = false
  /// Advances after every publication attempt so in-app readers re-read it.
  private(set) var publicationRevision = 0
  private let workspace: NativeWorkspace
  private let store: WidgetPublicationStore
  private let workspaceID: String
  private let replicaID: String
  private let preferencesURL: URL
  private let didChange: @MainActor () -> Void
  private let binding: NativeWorkspaceBinding?
  private var permit: WidgetPublicationPermit?
  private var revisionData: Data?
  private var alive = true
  private var refreshTask: Task<Void, Never>?
  private var pending = false
  private var partial = true
  private struct Preferences: Codable {
    let version: Int
    let workspaceID: String
    let replicaID: String
    let permit: WidgetPublicationPermit?
    let selections: [NativeWidgetSelection]
  }

  func pendingQuickAdd() throws -> WidgetQuickAdd? { try store.pendingQuickAdd() }
  func retainedQuickAdd() throws -> WidgetQuickAdd? { try store.retainedQuickAdd() }
  func discardQuickAdd(id: UUID) throws { try store.discardQuickAdd(id: id) }
  func finishQuickAdd(id: UUID) throws { try store.finishQuickAdd(id: id) }

  init(
    workspace: NativeWorkspace, library: WidgetLibrary, workspaceID: String,
    replicaID: String, preferencesURL: URL, binding: NativeWorkspaceBinding? = nil,
    didChange: @escaping @MainActor () -> Void = {}
  ) {
    self.workspace = workspace
    self.store = library.store(workspaceID: workspaceID)
    self.workspaceID = workspaceID
    self.replicaID = replicaID
    self.preferencesURL = preferencesURL
    self.binding = binding
    self.didChange = didChange
    do {
      guard let data = try readPreferences() else { return }
      let saved = try JSONDecoder().decode(Preferences.self, from: data)
      guard saved.version == 1, saved.workspaceID.utf8.elementsEqual(workspaceID.utf8),
        saved.replicaID.utf8.elementsEqual(replicaID.utf8), Self.valid(saved.selections)
      else { throw Self.failure }
      revisionData = data
      if let permit = saved.permit, store.isCurrent(permit) {
        self.permit = permit
        selections = saved.selections
      }
    } catch {
      unreadable = true
      self.error = "Widget settings could not be read. The saved file has been kept."
    }
  }

  @discardableResult func setSelections(_ next: [NativeWidgetSelection], partial: Bool) async
    -> Bool
  {
    guard alive, !busy, !unreadable, Self.valid(next) else { return false }
    busy = true
    defer { finish() }
    self.partial = partial
    do {
      let retained = Set(next.map(\.id))
      if selections.contains(where: { !retained.contains($0.id) }) {
        // Revocation first makes restored old preferences harmless if saving the
        // new preference file fails. It also invalidates other in-flight publishers.
        try store.revoke()
        permit = nil
      }
      let authorization: WidgetPublicationPermit? =
        next.isEmpty ? nil : (try permit ?? store.beginPublication())
      try save(next, permit: authorization)
      selections = next
      permit = authorization
      if !next.isEmpty { try await publish() }
      guard alive else { return false }
      error = nil
      return true
    } catch {
      if alive {
        try? store.recordRefreshFailure()
        self.error = error.localizedDescription
      }
      return false
    }
  }

  func refresh(partial: Bool) async {
    self.partial = partial
    guard alive, !unreadable, !selections.isEmpty else { return }
    guard !busy else {
      pending = true
      return
    }
    busy = true
    defer { finish() }
    do {
      try await publish()
      if alive { error = nil }
    } catch {
      if alive, !Task.isCancelled {
        try? store.recordRefreshFailure()
        self.error = error.localizedDescription
      }
    }
  }

  func scheduleRefresh(partial: Bool) {
    guard alive, !selections.isEmpty else { return }
    self.partial = partial
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, self.alive else { return }
      await self.refresh(partial: self.partial)
    }
  }

  /// Explicit recovery keeps the unread file and removes its old authorization.
  func resetUnreadSettings() throws {
    guard alive, !busy, unreadable else { throw Self.failure }
    try store.revoke()
    if FileManager.default.fileExists(atPath: preferencesURL.path) {
      let retained = preferencesURL.appendingPathExtension("unread-" + UUID().uuidString)
      try FileManager.default.moveItem(at: preferencesURL, to: retained)
    }
    revisionData = nil
    permit = nil
    selections = []
    unreadable = false
    error = nil
    didChange()
  }

  /// Closing the host keeps the last authorized publication available offline.
  func cancel() {
    alive = false
    refreshTask?.cancel()
    refreshTask = nil
  }

  /// Explicit access removal, unlike ordinary workspace closure.
  func revoke() throws {
    try store.revoke()
    defer { didChange() }
    refreshTask?.cancel()
    refreshTask = nil
    permit = nil
    selections = []
    pending = false
    try save([], permit: nil)
  }

  /// The in-app daily section reads exactly what the Today widget reads: the same
  /// protected publication, rebound to the calendar at `now`, stale state included.
  func presentation(_ selection: NativeWidgetSelection, now: Date) -> (
    WidgetPresentation, nextBoundary: Date?
  )? {
    guard selections.contains(where: { $0.id == selection.id }) else { return nil }
    let id = WidgetLibrary.sourceID(
      workspaceID: workspaceID, table: selection.table, viewID: selection.viewID, kind: .list)
    let result = store.read(
      sourceID: id, workspaceID: workspaceID, replicaID: replicaID, now: now, saveSuccess: false)
    let display = try? store.withCurrentPublication { metadata, _ in
      metadata.sources.first { $0.id.utf8.elementsEqual(id.utf8) }?.plan.displayColumn
    }
    return (
      WidgetPresentation(result, kind: .list, displayColumn: display ?? nil, rowLimit: 10),
      result.content?.nextBoundary
    )
  }

  /// Published display name (saved-view name or table) for pickers.
  func publishedTitle(_ selection: NativeWidgetSelection) -> String? {
    let id = WidgetLibrary.sourceID(
      workspaceID: workspaceID, table: selection.table, viewID: selection.viewID, kind: .list)
    return try? store.withCurrentPublication { metadata, _ in
      metadata.sources.first { $0.id.utf8.elementsEqual(id.utf8) }?.title
    }
  }

  private func finish() {
    busy = false
    publicationRevision += 1
    didChange()
    if pending {
      pending = false
      scheduleRefresh(partial: partial)
    }
  }

  private func publish() async throws {
    guard let permit, store.isCurrent(permit) else { throw Self.failure }
    var requests: [NativeWidgetSourceRequest] = []
    let catalog = try await workspace.catalog()
    for selection in selections {
      try Task.checkCancellation()
      var title = selection.table
      var revision: String?
      if let id = selection.viewID {
        let listed = try await workspace.listViews(table: selection.table)
        guard let view = listed.views.first(where: { $0.id.utf8.elementsEqual(id.utf8) }),
          view.deletedAt == nil, view.unavailable == nil, view.definition != nil,
          let updated = view.updatedAt
        else { throw Self.failure }
        title = view.name
        revision = updated
      }
      let openURL = try binding.map {
        try NativeDeepLink(
          destination: NativeDestination(table: selection.table, viewID: selection.viewID),
          workspace: $0
        ).url
      }
      let writable = try await workspace.writeability(table: selection.table)
      let allowsQuickAdd =
        writable.writable
        && catalog.tables.contains {
          $0["id"]?.text.utf8.elementsEqual(selection.table.utf8) == true
            && $0["readOnly"] == .bool(false)
        }
      for kind in CoreReadPlanKind.allCases {
        requests.append(
          NativeWidgetSourceRequest(
            id: WidgetLibrary.sourceID(
              workspaceID: workspaceID, table: selection.table,
              viewID: selection.viewID, kind: kind), title: title,
            plan: CorePrepareReadPlanArgs(
              workspaceID: workspaceID, replicaID: replicaID,
              table: selection.table, kind: kind, viewID: selection.viewID,
              expectedViewUpdatedAt: revision),
            openURL: openURL, allowsQuickAdd: kind == .list && allowsQuickAdd))
      }
    }
    try Task.checkCancellation()
    guard alive else { throw CancellationError() }
    try await NativeWidgetPublisher(workspace: workspace, store: store)
      .publish(requests, partial: partial, permit: permit)
  }

  private static func valid(_ values: [NativeWidgetSelection]) -> Bool {
    values.count <= 32 && Set(values.map(\.id)).count == values.count
      && values.allSatisfy {
        !$0.table.isEmpty && $0.table.utf8.count <= 512
          && ($0.viewID == nil || (!$0.viewID!.isEmpty && $0.viewID!.utf8.count <= 512))
      }
  }
  private func readPreferences() throws -> Data? {
    do {
      let values = try preferencesURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, let size = values.fileSize, size <= 65536 else {
        throw Self.failure
      }
      let data = try Data(contentsOf: preferencesURL)
      guard data.count <= 65536 else { throw Self.failure }
      return data
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      return nil
    }
  }
  private func save(_ values: [NativeWidgetSelection], permit: WidgetPublicationPermit?) throws {
    guard try readPreferences() == revisionData else {
      throw WorkspaceError(
        message: "Widget settings changed in another window. Reopen settings to retry.",
        violations: [])
    }
    let data = try JSONEncoder().encode(
      Preferences(
        version: 1, workspaceID: workspaceID,
        replicaID: replicaID, permit: permit, selections: values))
    guard data.count <= 65536 else { throw Self.failure }
    try FileManager.default.createDirectory(
      at: preferencesURL.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: preferencesURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete], ofItemAtPath: preferencesURL.path)
    #endif
    revisionData = data
  }
  private static var failure: WorkspaceError {
    WorkspaceError(
      message: "A widget source is unavailable. Open its table or saved view and try again.",
      violations: [])
  }
}
