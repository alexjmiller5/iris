import Foundation

extension WorkspaceModel {
  func pendingQuickAdd() throws -> WidgetQuickAdd? { try widgets?.pendingQuickAdd() }
  func retainedQuickAdd() throws -> WidgetQuickAdd? { try widgets?.retainedQuickAdd() }
  func discardQuickAdd(id: UUID) throws { try widgets?.discardQuickAdd(id: id) }

  func quickAddDestination(_ request: WidgetQuickAdd) throws -> NativeDestination {
    try requirePendingQuickAdd(request)
    let destination = try linkedDestination(NativeDeepLink(url: request.openURL))
    guard destination.table.utf8.elementsEqual(request.table.utf8), destination.rowID == nil
    else { throw quickAddUnavailable }
    return destination
  }

  /// The handoff is still the exact pending request for this workspace's link identity.
  /// Unlike link navigation this does not wait for rows: the opened table may be reloading.
  private func requirePendingQuickAdd(_ request: WidgetQuickAdd) throws {
    guard let retained = try pendingQuickAdd(), retained.id == request.id,
      try quickAddBytes(retained) == quickAddBytes(request),
      let destination = try? NativeDeepLink(url: request.openURL).destination(matching: linkBinding),
      destination.table.utf8.elementsEqual(request.table.utf8), destination.rowID == nil
    else { throw quickAddUnavailable }
  }

  /// Called only after ordinary guarded navigation. Fresh host authority, not
  /// publication eligibility, decides whether a recoverable editor can be made.
  func prepareQuickAdd(_ request: WidgetQuickAdd) async throws -> RecordEditorModel {
    try requirePendingQuickAdd(request)
    guard let context = editingContext,
      context.table.utf8.elementsEqual(request.table.utf8)
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
    try requirePendingQuickAdd(request)
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
