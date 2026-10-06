import Foundation
import Observation

@Observable @MainActor
final class RecordEditorModel {
  @ObservationIgnored private var markdownEditors: [Data: InlineMarkdownEditor] = [:]

  func markdownEditor(for field: CatalogField) -> InlineMarkdownEditor {
    let key = Data(field.id.utf8)
    if let retained = markdownEditors[key] { return retained }
    let next = InlineMarkdownEditor(field: field, value: draft.values[field.id] ?? "") {
      [weak self] in
      self?.setValue($0, for: field.id)
    }
    markdownEditors[key] = next
    return next
  }

  func collectMarkdownEditors(lock: Bool) async throws {
    // Include retained editors outside the visible Form viewport. A later field
    // failing to collect must leave earlier locked fields editable for recovery.
    do {
      for key in markdownEditors.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
        try await markdownEditors[key]?.collect(lock: lock)
      }
    } catch {
      resumeMarkdownEditors()
      throw error
    }
  }

  func resumeMarkdownEditors() {
    for editor in markdownEditors.values { editor.session.resumeEditing?() }
  }

  func refreshMarkdownEditors() {
    // Only call after an explicit recovery/Undo transition, never ordinary typing.
    for editor in markdownEditors.values {
      editor.session.begin(
        value: draft.values[editor.fieldID] ?? "", label: editor.session.document.label,
        readOnly: isTrashed)
      editor.coordinator.render()
    }
  }

  func endInlineMarkdown() {
    for editor in markdownEditors.values { editor.stop() }
    markdownEditors.removeAll()
  }

  private(set) var draft: RecordDraft
  private(set) var recoveryChoices: [StoredEditorDraft] = []
  var recovery: StoredEditorDraft? { recoveryChoices.first }
  private(set) var failure: String?
  private(set) var violations: [Violation] = []
  private(set) var saving = false
  private(set) var autosavePaused = false
  private var undoUnconfirmed = false
  private(set) var undoing = false
  var isTrashed: Bool { draft.original?["deleted_at"]?.text.nonempty != nil }

  func performUndo(
    _ action: CoreUndoAction,
    isCurrent: @MainActor () -> Bool = { true },
    collect: @MainActor () async throws -> Void = {},
    operation: @MainActor () async throws -> WorkspaceRecord
  ) async throws {
    guard !saving, recovery == nil, !unreadableDraft, !reviewRequired, isCurrent() else {
      throw WorkspaceError(message: "Finish the current operation before undoing.", violations: [])
    }
    debounceTask?.cancel()
    autosavePaused = true
    undoUnconfirmed = true
    undoing = true
    saving = true
    defer {
      undoing = false
      saving = false
    }
    do {
      // Only draft/review state is durable. The core receipt stays in memory.
      try persist()
      try await collect()
      guard isCurrent(), !Task.isCancelled else {
        throw WorkspaceError(
          message: "The editor changed. Your draft has been kept.", violations: [])
      }
      // setValue reports journal failures to the UI without throwing. Recheck
      // durability after collecting the live document, before any inverse write.
      try persist()
      let receipt = try await operation()
      guard isCurrent() else {
        throw WorkspaceError(
          message: "The editor changed. Your draft has been kept for review.", violations: [])
      }
      if action.table == table
        && Data(action.rowId.utf8) == (draft.original?["id"]?.text).map({ Data($0.utf8) })
      {
        draft.reconcileUndo(receipt)
      }
      undoUnconfirmed = false
      autosavePaused = dirty || isTrashed
      failedPatch = nil
      failure = nil
      violations = []
      try persist()
    } catch {
      undoUnconfirmed = false
      failure = error.localizedDescription
      violations = (error as? WorkspaceError)?.violations ?? []
      try? persist()
      throw error
    }
  }
  private var failedPatch: WorkspaceRecord?
  private var debounceTask: Task<Void, Never>?
  private var inFlight: Task<Void, any Error>?
  private let table: String
  private let recordID: String?
  private let store: EditorDraftStore?
  private let debounce: Duration
  private let write: @MainActor (WorkspaceRecord, WorkspaceRecord?) async throws -> WorkspaceRecord
  private var unreadableDraft = false
  private var journalID = UUID().uuidString
  private var pendingWrite: PendingEditorWrite?
  private var reviewRequired = false
  private final class Owner {
    weak var editor: RecordEditorModel?
    init(_ editor: RecordEditorModel) { self.editor = editor }
  }
  private static var owners: [String: Owner] = [:]
  private func ownerKey(_ id: String) -> String {
    (store?.directory.path ?? "temporary") + "/" + id
  }

  init(
    properties: [WorkspaceRecord], original: WorkspaceRecord?, table: String,
    store: EditorDraftStore?, debounce: Duration = .milliseconds(600),
    recovered: StoredEditorDraft? = nil,
    write: @escaping @MainActor (WorkspaceRecord, WorkspaceRecord?) async throws -> WorkspaceRecord
  ) {
    draft = RecordDraft(properties: properties, original: original)
    self.table = table
    recordID = recovered != nil ? recovered!.recordID : original?["id"]?.text
    self.store = store
    self.debounce = debounce
    self.write = write
    do {
      recoveryChoices =
        try recovered.map { [$0] }
        ?? store?.all().filter {
          $0.table == table && $0.recordID.map { Data($0.utf8) } == recordID.map { Data($0.utf8) }
        } ?? []
    } catch {
      unreadableDraft = true
      failure = "The saved draft could not be opened. It has been kept."
    }
    Self.owners = Self.owners.filter { $0.value.editor != nil }
    Self.owners[ownerKey(journalID)] = Owner(self)
  }

  var dirty: Bool { draft.patch.keys.contains { $0 != "id" } || !draft.unknownValues.isEmpty }
  var needsReview: Bool { reviewRequired }
  var isNew: Bool { draft.original == nil }
  var markdownSaved: Bool {
    !isNew && !saving && failure == nil && recovery == nil
      && !markdownPatch.keys.contains(where: { $0 != "id" })
  }
  var markdownPatch: WorkspaceRecord {
    let columns = Set(draft.fields.filter { $0.type == "markdown" }.map(\.id))
    return draft.patch.filter { $0.key == "id" || columns.contains($0.key) }
  }
  var status: String {
    if let failure { return failure }
    if undoing { return "Undoing saved change…" }
    if saving { return "Saving…" }
    if isTrashed { return "This record is in the trash. Restore it before saving your draft." }
    if autosavePaused { return "Autosave paused. Review your draft, then save the record." }
    if isNew { return "Draft · Save the record to keep it" }
    return markdownSaved ? "Saved on this device" : "Unsaved changes"
  }

  /// Prepare a fresh editor before presenting it or changing navigation context.
  /// Existing recovery variants remain on disk; this review owns its own journal.
  func installRejectedDraft(submitted: WorkspaceRecord) throws {
    guard !saving, !dirty, !autosavePaused, !unreadableDraft, !reviewRequired,
      case .string(let currentID)? = draft.original?["id"],
      case .string(let submittedID)? = submitted["id"],
      Data(currentID.utf8) == Data(submittedID.utf8)
    else {
      throw WorkspaceError(
        message: "Open the current saved record before reviewing the rejected edit.", violations: []
      )
    }
    debounceTask?.cancel()
    let previous = draft
    let recoveries = recoveryChoices
    for field in draft.fields {
      if let value = submitted[field.id] { draft.values[field.id] = field.formValue(value) }
    }
    recoveryChoices = []
    autosavePaused = true
    do {
      try persist()
    } catch {
      draft = previous
      recoveryChoices = recoveries
      autosavePaused = false
      throw error
    }
  }

  func installDuplicateDraft(
    from row: WorkspaceRecord, isCurrent: @MainActor () -> Bool = { true }
  ) throws {
    guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    guard isNew, recordID == nil, !saving, !dirty, !autosavePaused,
      !unreadableDraft, !reviewRequired, failure == nil
    else {
      throw WorkspaceError(message: "Start a new editor before preparing a copy.", violations: [])
    }
    let previous = draft
    let recoveries = recoveryChoices
    for field in draft.fields {
      if let value = row[field.id] {
        draft.setValue(
          field.formValue(value), for: field.id, preservingEmptyString: value == .string(""))
      }
    }
    recoveryChoices = []
    do {
      // Copying is explicit creation intent even when every source column is
      // excluded. Keep its own nil-recordID journal before the host presents it.
      try persist(keepEmpty: true)
    } catch {
      draft = previous
      recoveryChoices = recoveries
      throw error
    }
  }

  func setValue(_ value: String, for column: String, explicit: Bool = false) {
    guard recovery == nil,
      explicit || draft.values[column].map({ Data($0.utf8) }) != Data(value.utf8),
      draft.setValue(value, for: column)
    else {
      return
    }
    if failedPatch?[column] != nil && !reviewRequired && !autosavePaused {
      failedPatch = nil
      failure = nil
      violations = []
    }
    do { try persist() } catch {
      failure = "Could not keep a recovery draft. " + error.localizedDescription
      return
    }
    guard !isNew, !autosavePaused, !isTrashed,
      draft.fields.contains(where: { $0.id == column && $0.type == "markdown" })
    else {
      return
    }
    debounceTask?.cancel()
    debounceTask = Task { [weak self, debounce] in
      do { try await Task.sleep(for: debounce) } catch { return }
      try? await self?.flushMarkdown()
    }
  }

  func resumeDraft(_ selected: StoredEditorDraft? = nil) {
    guard let recovery = selected ?? recovery,
      recoveryChoices.contains(where: { $0.id == recovery.id })
    else { return }
    // A live window keeps its own journal. Resuming its draft in another window
    // forks a separate variant instead of sharing deletion/write ownership.
    if Self.owners[ownerKey(recovery.id)]?.editor == nil {
      Self.owners.removeValue(forKey: ownerKey(journalID))
      journalID = recovery.id
      Self.owners[ownerKey(journalID)] = Owner(self)
    }
    let changed = draft.original?["updated_at"] != recovery.draft.original?["updated_at"]
    draft = recovery.draft
    pendingWrite = recovery.pendingWrite
    undoUnconfirmed = recovery.undoUnconfirmed == true
    autosavePaused = recovery.autosavePaused == true
    reviewRequired = pendingWrite != nil || undoUnconfirmed
    failure =
      reviewRequired
      ? "A previous save did not finish confirming. Your draft has been kept for review."
      : changed
        ? "This record changed while the draft was closed. Your draft has been kept."
        : recovery.failure
    failedPatch = recovery.failedPatch
    recoveryChoices = []
    do { try persist() } catch { failure = error.localizedDescription }
    // Recovery never silently replays a write, especially with a stale revision.
  }

  func discardDraft() throws {
    guard !saving else {
      throw WorkspaceError(message: "Wait for the current save to finish.", violations: [])
    }
    debounceTask?.cancel()
    try store?.remove(table: table, recordID: recordID, draftID: journalID)
    recoveryChoices = []
  }

  func keepDraft() throws {
    debounceTask?.cancel()
    try persist()
  }

  func keepDraft(collect: @MainActor () async throws -> Void) async throws {
    debounceTask?.cancel()
    try await collect()
    try keepDraft()
  }

  func openSavedRecord() {
    // The current editor still has the freshly loaded row and its revision.
    // Leave every recovery variant available for a separate review.
    recoveryChoices = []
  }

  func discardRecovery(_ saved: StoredEditorDraft) throws {
    guard Self.owners[ownerKey(saved.id)]?.editor == nil else {
      throw WorkspaceError(
        message: "This draft is open in another window. Close it there before discarding.",
        violations: [])
    }
    try store?.remove(table: saved.table, recordID: saved.recordID, draftID: saved.id)
    recoveryChoices.removeAll { $0.id == saved.id }
  }

  func flushMarkdown(retry: Bool = false) async throws {
    debounceTask?.cancel()
    guard !undoing, !autosavePaused, !isTrashed else {
      throw WorkspaceError(message: status, violations: violations)
    }
    if retry { failedPatch = nil }
    guard !isNew else {
      try persist()
      return
    }
    try checkRecovery()
    while true {
      if let inFlight {
        try await inFlight.value
        continue
      }
      let patch = markdownPatch
      guard patch.keys.contains(where: { $0 != "id" }) else {
        if let failure { throw WorkspaceError(message: failure, violations: violations) }
        return
      }
      try await submit(patch)
    }
  }

  func saveAll(_ explicitPatch: WorkspaceRecord? = nil) async throws {
    debounceTask?.cancel()
    guard !undoing else {
      throw WorkspaceError(message: "Wait for Undo to finish.", violations: [])
    }
    while let inFlight { try await inFlight.value }
    try checkRecovery()
    guard !isTrashed || explicitPatch?["deleted_at"] == .null else {
      throw WorkspaceError(message: "Restore this record before saving the draft.", violations: [])
    }
    failedPatch = nil
    let patch = explicitPatch ?? draft.patch
    if isNew || patch.keys.contains(where: { $0 != "id" }) {
      try await submit(patch)
    } else {
      if let failure { throw WorkspaceError(message: failure, violations: violations) }
      try persist()
    }
    if explicitPatch == nil { autosavePaused = false }
    try persist()
  }

  private func checkRecovery() throws {
    if reviewRequired {
      throw WorkspaceError(
        message: failure ?? "Review the recovered draft before saving.", violations: [])
    }
  }

  private func submit(_ patch: WorkspaceRecord) async throws {
    guard recovery == nil, !unreadableDraft else {
      throw WorkspaceError(
        message: "Open or discard the saved draft before saving.", violations: [])
    }
    if failedPatch == patch {
      throw WorkspaceError(
        message: failure ?? "The edit could not be saved.", violations: violations)
    }
    saving = true
    pendingWrite = PendingEditorWrite(
      id: UUID().uuidString, patch: patch,
      expectedUpdatedAt: draft.original?["updated_at"]?.text)
    let task = Task { @MainActor in
      defer {
        self.saving = false
        self.inFlight = nil
      }
      do {
        try self.persist()
        let receipt = try await self.write(patch, self.draft.original)
        self.draft.acknowledge(receipt, sent: patch)
        self.pendingWrite = nil
        self.failedPatch = nil
        self.failure = nil
        self.violations = []
        try self.persist()
      } catch {
        self.pendingWrite = nil
        self.failedPatch = patch
        self.failure = error.localizedDescription
        self.violations = (error as? WorkspaceError)?.violations ?? []
        // Keep the failed patch and every later keystroke available after relaunch.
        try? self.persist()
        throw error
      }
    }
    inFlight = task
    try await task.value
  }

  private func persist(keepEmpty: Bool = false) throws {
    guard !unreadableDraft else {
      throw WorkspaceError(
        message: "The saved draft has been kept. It could not be opened.", violations: [])
    }
    guard recovery == nil else { return }
    if keepEmpty || dirty || failure != nil || pendingWrite != nil || undoUnconfirmed
      || autosavePaused
    {
      try store?.save(
        StoredEditorDraft(
          id: journalID, table: table, recordID: recordID, draft: draft,
          failure: failure, failedPatch: failedPatch, pendingWrite: pendingWrite,
          autosavePaused: autosavePaused, undoUnconfirmed: undoUnconfirmed))
    } else {
      try store?.remove(table: table, recordID: recordID, draftID: journalID)
    }
  }
}
