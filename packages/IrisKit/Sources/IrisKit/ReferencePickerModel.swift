import Foundation
import Observation

/// Creates a related record through the ordinary editor model and local writer.
struct ReferenceCreator {
  let table: String
  let display: String
  let properties: [WorkspaceRecord]
  let workspace: NativeWorkspace
  let write: @MainActor (WorkspaceRecord) async throws -> WorkspaceRecord

  /// A writable target whose display property the typed text can fill.
  static func target(
    of field: CatalogField, tables: [WorkspaceRecord], properties: [WorkspaceRecord]
  ) -> (table: String, display: String)? {
    guard let table = field.property["ref_table"]?.text.nonempty,
      let entry = tables.first(where: { $0["id"]?.text == table }),
      entry["readOnly"] == .bool(false),
      let display = entry["display"]?.text.nonempty,
      !["id", "created_at", "updated_at", "deleted_at", "hub_at"].contains(display),
      let title = properties.first(where: {
        $0["tbl"]?.text == table && $0["col"]?.text == display
      }),
      title["derived_by"]?.text.nonempty == nil, title["deprecated"]?.isTrue != true
    else { return nil }
    return (table, display)
  }

  /// A new-record editor named by the typed text. Untouched defaults stay omitted for core.
  @MainActor func editor(named text: String) -> RecordEditorModel {
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: table, store: nil
    ) { patch, _ in try await write(patch) }
    editor.setValue(text, for: display)
    return editor
  }

  /// Required fields besides the name that have no catalog default.
  func missing(in draft: RecordDraft) -> [CatalogField] {
    draft.fields.filter {
      $0.required && $0.id != display
        && ($0.property["default_value"] == nil || $0.property["default_value"] == .null)
    }
  }
}

@Observable @MainActor
final class ReferencePickerModel {
  let table: String
  private(set) var selection: ReferenceSelection
  private(set) var rows: [WorkspaceRow] = []
  private(set) var loading = false
  private(set) var canLoadMore = false
  private(set) var error: String?
  var search = ""
  let creator: ReferenceCreator?
  /// A new record with required fields left, awaiting the editor sheet's Save or Cancel.
  private(set) var creation: RecordEditorModel?
  private(set) var creating = false
  private var labels: [Data: String] = [:]
  private var revision = 0
  private let load: (CoreView) async throws -> [WorkspaceRow]

  init(
    table: String, value: String, multiple: Bool, creator: ReferenceCreator? = nil,
    load: @escaping (CoreView) async throws -> [WorkspaceRow]
  ) throws {
    self.table = table
    selection = try ReferenceSelection(value: value, multiple: multiple)
    self.creator = creator
    self.load = load
  }

  /// The trimmed search text, unless a loaded record already has that exact name.
  var creationOffer: String? {
    let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard creator != nil, !creating, creation == nil, !text.isEmpty,
      !rows.contains(where: { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == text })
    else { return nil }
    return text
  }

  /// Creates directly when only the name is needed; otherwise hands the draft to the editor.
  func create(_ text: String) async {
    guard let creator, !creating, creation == nil else { return }
    let editor = creator.editor(named: text)
    if creator.missing(in: editor.draft).isEmpty {
      await save(editor)
    } else {
      creation = editor
    }
  }

  /// Saves through validation, then selects the new record's exact id. Failures keep the draft.
  func save(_ editor: RecordEditorModel) async {
    guard let creator, !creating else { return }
    creating = true
    error = nil
    defer { creating = false }
    do {
      try await editor.saveAll()
      guard case .string(let id)? = editor.draft.original?["id"] else { return }
      labels[Data(id.utf8)] = editor.draft.original?[creator.display]?.text.nonempty ?? id
      if !selection.contains(id) { selection.choose(id) }
      creation = nil
      await reload()
    } catch {
      // The hand-off sheet shows the editor's own failure and violations.
      if creation !== editor { self.error = error.localizedDescription }
    }
  }

  func cancelCreation() { creation = nil }

  func label(for id: String) -> String { labels[Data(id.utf8)] ?? "Unavailable" }

  func choose(_ row: WorkspaceRow) {
    labels[row.byteExactID] = row.label
    selection.choose(row.id)
  }

  func remove(_ id: String) { selection.remove(id) }

  func resolveSelected() async {
    for id in selection.ids {
      do {
        let result = try await load(
          CoreView(
            table: table, filters: [CoreFilter(column: "id", op: .eq, value: .string(id))], limit: 1
          ))
        guard !Task.isCancelled else { return }
        if let row = result.first(where: { $0.byteExactID == Data(id.utf8) }) {
          labels[row.byteExactID] = row.label
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func reload(more: Bool = false) async {
    revision += 1
    let request = revision
    let query = search
    loading = true
    error = nil
    do {
      let result = try await load(
        CoreView(table: table, limit: 100, offset: more ? rows.count : 0, search: query))
      guard request == revision, query == search, !Task.isCancelled else { return }
      rows = more ? rows + result : result
      for row in result { labels[row.byteExactID] = row.label }
      canLoadMore = result.count == 100
    } catch {
      guard request == revision, query == search, !Task.isCancelled else { return }
      self.error = error.localizedDescription
      if !more { rows = [] }
    }
    loading = false
  }

  func invalidateSearch() {
    revision += 1
    loading = false
  }
}
