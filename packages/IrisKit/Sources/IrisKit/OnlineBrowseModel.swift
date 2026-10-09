import Foundation
import Observation

extension CoreRemoteRecord: Identifiable {
  public var id: String { record["id"]?.text ?? "" }
  public var byteExactID: Data { Data(id.utf8) }
}

@Observable @MainActor
final class OnlineBrowseModel: Identifiable {
  let id = UUID()
  let table: String
  private(set) var rows: [CoreRemoteRecord] = []
  private(set) var nextCursor: String?
  private(set) var loading = false
  private(set) var opening: String?
  private(set) var error: String?
  private(set) var openError: String?
  var selected: CoreRemoteRecord?
  var recordID = "" {
    didSet {
      guard !oldValue.utf8.elementsEqual(recordID.utf8) else { return }
      openRevision += 1
      opening = nil
      selected = nil
      openError = nil
    }
  }
  private var active = true
  private var pageRevision = 0
  private var openRevision = 0
  private let isCurrent: () -> Bool
  private let load: (String?) async throws -> CoreRemoteRowsPage
  private let read: (String) async throws -> CoreRemoteRowResult

  init(
    table: String, load: @escaping (String?) async throws -> CoreRemoteRowsPage,
    read: @escaping (String) async throws -> CoreRemoteRowResult,
    isCurrent: @escaping () -> Bool = { true }
  ) {
    self.table = table
    self.load = load
    self.read = read
    self.isCurrent = isCurrent
  }

  func reload(more: Bool = false) async {
    guard active, isCurrent(), !more || (!loading && nextCursor != nil) else { return }
    pageRevision += 1
    openRevision += 1
    let request = pageRevision
    opening = nil
    selected = nil
    openError = nil
    if !more {
      rows = []
      nextCursor = nil
    }
    loading = true
    error = nil
    defer { if request == pageRevision { loading = false } }
    do {
      let page = try await load(more ? nextCursor : nil)
      guard active, isCurrent(), request == pageRevision else { return }
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
      nextCursor = page.nextCursor
    } catch {
      guard active, isCurrent(), request == pageRevision else { return }
      self.error = error.localizedDescription
    }
  }

  func open(_ row: CoreRemoteRecord) async {
    await open(id: row.id)
  }

  func open(id: String) async {
    guard active, isCurrent() else { return }
    guard !id.isEmpty else {
      openError = "Enter a record ID."
      return
    }
    openRevision += 1
    let request = openRevision
    opening = id
    selected = nil
    openError = nil
    defer { if request == openRevision { opening = nil } }
    do {
      let result = try await read(id)
      guard active, isCurrent(), request == openRevision else { return }
      selected = result.row
      if result.row == nil {
        openError =
          "This record is no longer available on the hub. Refresh the list to see current records."
      }
    } catch {
      guard active, isCurrent(), request == openRevision else { return }
      openError = error.localizedDescription
    }
  }

  func cancel() {
    recordID = ""
    active = false
    pageRevision += 1
    openRevision += 1
    rows = []
    nextCursor = nil
    selected = nil
    error = nil
    openError = nil
    loading = false
    opening = nil
  }
}
