import Foundation

extension WorkspaceModel {
  func pendingQuickAdd() throws -> WidgetQuickAdd? { try widgets?.pendingQuickAdd() }
  func retainedQuickAdd() throws -> WidgetQuickAdd? { try widgets?.retainedQuickAdd() }
  func discardQuickAdd(id: UUID) throws { try widgets?.discardQuickAdd(id: id) }

  func quickAddDestination(_ request: WidgetQuickAdd) throws -> NativeDestination {
    guard let retained = try pendingQuickAdd(), retained.id == request.id,
      try quickAddBytes(retained) == quickAddBytes(request)
    else { throw quickAddUnavailable }
    let destination = try linkedDestination(NativeDeepLink(url: request.openURL))
    guard destination.table.utf8.elementsEqual(request.table.utf8), destination.rowID == nil
    else { throw quickAddUnavailable }
    return destination
  }

  /// Called only after ordinary guarded navigation. Fresh host authority, not
  /// publication eligibility, decides whether a recoverable editor can be made.
  func prepareQuickAdd(_ request: WidgetQuickAdd) async throws -> RecordEditorModel {
    let destination = try quickAddDestination(request)
    guard let context = editingContext,
      context.table.utf8.elementsEqual(destination.table.utf8)
    else { throw quickAddUnavailable }
    let generation = workspaceGeneration
    let current = {
      self.client === context.workspace && self.workspaceGeneration == generation
        && self.table?.utf8.elementsEqual(context.table.utf8) == true
    }
    let catalog = try await context.workspace.catalog()
    let availability = try await context.workspace.writeability(table: context.table)
    guard current(), !Task.isCancelled, availability.writable,
      catalog.tables.contains(where: {
        $0["id"]?.text.utf8.elementsEqual(context.table.utf8) == true
          && $0["readOnly"] == .bool(false)
      })
    else { throw quickAddUnavailable }
    _ = try quickAddDestination(request)
    let properties = catalog.properties.filter {
      $0["tbl"]?.text.utf8.elementsEqual(context.table.utf8) == true
    }
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: context.table, store: context.draftStore
    ) {
      patch, baseline in try await self.save(patch, original: baseline, context: context)
    }
    try editor.installCaptureDraft(id: request.id, text: request.text, column: request.column)
    // Durable editor journal exists before removing the cross-process handoff.
    // Failed acknowledgement keeps the journal and request for idempotent recovery.
    try widgets?.finishQuickAdd(id: request.id)
    return editor
  }
}

private func quickAddBytes(_ request: WidgetQuickAdd) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  return try encoder.encode(request)
}
private let quickAddUnavailable = WorkspaceError(
  message: "Quick Add is unavailable in this workspace. Its input has been kept.", violations: [])
