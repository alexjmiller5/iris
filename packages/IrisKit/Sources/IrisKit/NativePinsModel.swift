import Foundation
import Observation

/// Disposable UI state. Pin authority remains the workspace's ordinary synced rows.
@Observable @MainActor
final class NativePinsModel {
  private(set) var snapshot: CoreSidebarPinList?
  private(set) var loading = false
  private(set) var busy = false
  private(set) var error: String?
  private var revision = 0
  private var valid = true
  private let read: () async throws -> CoreSidebarPinList
  private let writePin: (CorePinTableArgs) async throws -> CoreSidebarPinList
  private let writeUnpin: (CoreUnpinTableArgs) async throws -> CoreSidebarPinList
  private let writeMove: (CoreMoveTablePinArgs) async throws -> CoreSidebarPinList
  private let isCurrent: () -> Bool
  private let didCommit: () async -> Void

  init(
    list: @escaping () async throws -> CoreSidebarPinList,
    pin: @escaping (CorePinTableArgs) async throws -> CoreSidebarPinList,
    unpin: @escaping (CoreUnpinTableArgs) async throws -> CoreSidebarPinList,
    move: @escaping (CoreMoveTablePinArgs) async throws -> CoreSidebarPinList,
    isCurrent: @escaping () -> Bool = { true }, didCommit: @escaping () async -> Void = {}
  ) {
    read = list
    writePin = pin
    writeUnpin = unpin
    writeMove = move
    self.isCurrent = isCurrent
    self.didCommit = didCommit
  }
  var active: [CoreSidebarPin] { snapshot?.pins.filter { $0.deletedAt == nil } ?? [] }
  private var current: Bool { valid && isCurrent() }
  var disabled: Bool {
    !current || busy || loading || error != nil || snapshot == nil || snapshot?.unavailable != nil
  }
  func cancel() {
    valid = false
    revision += 1
    loading = false
    busy = false
    snapshot = nil
  }

  func refresh() async {
    guard current, !busy else { return }
    revision += 1
    let request = revision
    loading = true
    defer { if request == revision { loading = false } }
    do {
      let receipt = try await read()
      guard current, request == revision else { return }
      snapshot = receipt
      error = nil
    } catch {
      guard current, request == revision else { return }
      self.error = error.localizedDescription
    }
  }
  private func mutate(_ write: () async throws -> CoreSidebarPinList) async -> Bool {
    guard !disabled else { return false }
    revision += 1
    let request = revision
    busy = true
    defer { if request == revision { busy = false } }
    do {
      let receipt = try await write()
      guard current, request == revision else { return false }
      snapshot = receipt
      error = nil
      await didCommit()
      return true
    } catch {
      guard current, request == revision else { return false }
      self.error = error.localizedDescription
      return false
    }
  }
  @discardableResult func pin(_ table: String) async -> Bool {
    let args = CorePinTableArgs(
      table: table, expectedUpdatedAt: snapshot?.pins.first { $0.tbl == table }?.updatedAt)
    return await mutate { try await writePin(args) }
  }
  @discardableResult func unpin(_ id: String) async -> Bool {
    guard let selected = active.first(where: { $0.id == id }) else { return false }
    let args = CoreUnpinTableArgs(id: id, expectedUpdatedAt: selected.updatedAt)
    return await mutate { try await writeUnpin(args) }
  }
  @discardableResult func move(_ id: String, direction: String) async -> Bool {
    let args = CoreMoveTablePinArgs(
      id: id, direction: direction,
      expected: active.map { CorePinRevision(id: $0.id, updatedAt: $0.updatedAt) })
    return await mutate { try await writeMove(args) }
  }
}
