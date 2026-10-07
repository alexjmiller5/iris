import Foundation
import Observation

struct BulkRecordResult: Identifiable {
  enum Status { case succeeded, failed, unattempted }
  let recordID: String
  var id: Data { Data(recordID.utf8) }
  var status: Status = .unattempted
  var row: WorkspaceRecord?
  var error: String?
}

@Observable @MainActor
final class BulkRecordModel {
  private(set) var results: [BulkRecordResult]
  private(set) var running = false
  private(set) var error: String?
  private var cancelled = false
  private let authorize: () async throws -> Void
  private let read: (String) async throws -> WorkspaceRecord
  private let write: (WorkspaceRecord, String) async throws -> WorkspaceRecord
  private let isCurrent: () -> Bool
  init(
    ids: [String], authorize: @escaping () async throws -> Void,
    read: @escaping (String) async throws -> WorkspaceRecord,
    write: @escaping (WorkspaceRecord, String) async throws -> WorkspaceRecord,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    results = ids.map { BulkRecordResult(recordID: $0) }
    self.authorize = authorize
    self.read = read
    self.write = write
    self.isCurrent = isCurrent
  }
  convenience init(
    workspace: NativeWorkspace, table: String, ids: [String],
    isCurrent: @escaping () -> Bool = { true },
    write: ((WorkspaceRecord, String) async throws -> WorkspaceRecord)? = nil
  ) {
    self.init(
      ids: ids,
      authorize: {
        let permission = try await workspace.writeability(table: table)
        guard permission.writable else {
          throw WorkspaceError(
            message: permission.reason?.message ?? "This table is read-only.", violations: [])
        }
      },
      read: { id in
        let rows = try await workspace.rows(
          view: CoreView(
            table: table, filters: [.init(column: "id", op: .eq, value: .string(id))], limit: 2))
        guard rows.count == 1 else {
          throw WorkspaceError(
            message: "This record is no longer available locally.", violations: [])
        }
        return rows[0].record
      },
      write: write ?? { patch, revision in
        try await workspace.write(table: table, patch: patch, expectedUpdatedAt: revision)
      }, isCurrent: isCurrent)
  }
  private var stopped: Bool { cancelled || !isCurrent() }

  /// Reserve synchronously so dismissal can cancel an action not yet admitted.
  func start(values: WorkspaceRecord) -> Task<Void, Never>? {
    guard !running else { return nil }
    let ids = results.map(\.recordID)
    guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }),
      Set(ids.map { Data($0.utf8) }).count == ids.count,
      !values.isEmpty,
      !values.keys.contains(where: { ["id", "created_at", "updated_at", "hub_at"].contains($0) })
    else {
      error = "Choose unique records and an editable property."
      return nil
    }
    results = ids.map { BulkRecordResult(recordID: $0) }
    error = nil
    cancelled = false
    running = true
    return Task {
      defer { running = false }
      guard !stopped else { return }
      do { try await authorize() } catch {
        if !stopped { self.error = error.localizedDescription }
        return
      }
      for (index, id) in ids.enumerated() {
        guard !stopped else { break }
        var writing = false
        do {
          let row = try await read(id)
          guard !stopped else { break }
          guard case .string(let loadedID) = row["id"], Data(loadedID.utf8) == Data(id.utf8),
            row["deleted_at"] == nil || row["deleted_at"] == .null,
            case .string(let revision) = row["updated_at"], !revision.isEmpty
          else {
            throw WorkspaceError(
              message: "This record or its revision is no longer available locally.", violations: []
            )
          }
          var patch = values
          patch["id"] = .string(id)
          writing = true
          let receipt = try await write(patch, revision)
          // An admitted write owns its receipt even after cancellation/navigation.
          results[index] = BulkRecordResult(recordID: id, status: .succeeded, row: receipt)
        } catch {
          if !writing && stopped { break }
          results[index] = BulkRecordResult(
            recordID: id, status: .failed, error: error.localizedDescription)
        }
      }
    }
  }
  func cancelRemaining() { cancelled = true }
}
