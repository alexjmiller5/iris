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
  private let workspace: NativeWorkspace
  private let store: WidgetPublicationStore
  private let workspaceID: String
  private let replicaID: String
  private let preferencesURL: URL
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

  init(
    workspace: NativeWorkspace, library: WidgetLibrary, workspaceID: String,
    replicaID: String, preferencesURL: URL
  ) {
    self.workspace = workspace
    self.store = library.store(workspaceID: workspaceID)
    self.workspaceID = workspaceID
    self.replicaID = replicaID
    self.preferencesURL = preferencesURL
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

  /// Closing the host keeps the last authorized publication available offline.
  func cancel() {
    alive = false
    refreshTask?.cancel()
    refreshTask = nil
  }

  /// Explicit access removal, unlike ordinary workspace closure.
  func revoke() throws {
    try store.revoke()
    refreshTask?.cancel()
    refreshTask = nil
    permit = nil
    selections = []
    pending = false
    try save([], permit: nil)
  }

  private func finish() {
    busy = false
    if pending {
      pending = false
      scheduleRefresh(partial: partial)
    }
  }

  private func publish() async throws {
    guard let permit, store.isCurrent(permit) else { throw Self.failure }
    var requests: [NativeWidgetSourceRequest] = []
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
      for kind in CoreReadPlanKind.allCases {
        requests.append(
          NativeWidgetSourceRequest(
            id: WidgetLibrary.sourceID(
              workspaceID: workspaceID, table: selection.table,
              viewID: selection.viewID, kind: kind), title: title,
            plan: CorePrepareReadPlanArgs(
              workspaceID: workspaceID, replicaID: replicaID,
              table: selection.table, kind: kind, viewID: selection.viewID,
              expectedViewUpdatedAt: revision)))
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
