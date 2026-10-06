import Foundation
import Testing
import WebKit

@testable import LifeKit

@MainActor
struct MarkdownEditorTests {
  @Test func switchingDocumentsRejectsOldCallbacksAndReadOnlyChanges() throws {
    let session = MarkdownEditorSession(value: "# Original", label: "Body")
    var changes: [String] = []
    session.onChange = { changes.append($0) }
    let old = session.document.id
    session.begin(value: "# Other", label: "Description", readOnly: false)
    #expect(old != session.document.id)
    session.receive(["type": "change", "id": old, "value": "stale"])
    #expect(session.document.value == "# Other")
    session.receive(["type": "change", "id": session.document.id, "value": "edited"])
    #expect(changes == ["edited"])
    session.begin(value: "Protected", label: "Body", readOnly: true)
    session.receive(["type": "change", "id": session.document.id, "value": "must not apply"])
    #expect(session.document.value == "Protected")
    session.invalidate()
    session.receive(["type": "change", "id": session.document.id, "value": "closed"])
    #expect(changes == ["edited"])
  }

  @Test func fallbackRetainsSourceAndFinishUsesTheMatchingLiveSnapshot() throws {
    let session = MarkdownEditorSession(value: "# Before", label: "Body")
    session.editSource("# Typed while loading")
    session.fail("Synthetic unavailable editor")
    #expect(session.document.value == "# Typed while loading")
    #expect(!session.ready)
    #expect(throws: WorkspaceError.self) {
      try session.acceptSnapshot(
        MarkdownDocument(id: "stale", value: "wrong", label: "Body", readOnly: false))
    }
    try session.acceptSnapshot(
      MarkdownDocument(
        id: session.document.id, value: "# Final keystroke", label: "Body", readOnly: false))
    #expect(session.document.value == "# Final keystroke")
  }

  @Test func backgroundSnapshotDoesNotLockOrReplaceLaterDeliveredTyping() async throws {
    let session = MarkdownEditorSession(value: "Before", label: "Body")
    session.markReady()
    session.snapshot = { lock in
      #expect(!lock)
      let captured = session.document
      session.editSource("Later delivered change!")
      return captured
    }
    try await session.collectSnapshot(lock: false)
    #expect(session.document.value == "Later delivered change!")
    session.snapshot = { lock in
      #expect(!lock)
      return MarkdownDocument(
        id: session.document.id, value: "Final live value!",
        label: "Body", readOnly: false)
    }
    try await session.collectSnapshot(lock: false)
    #expect(session.document.value == "Final live value!")
  }

  @Test func bundledEditorUndoHistoryCannotCrossDocumentIdentity() async throws {
    let session = MarkdownEditorSession(value: "# First\n\nOriginal", label: "Body")
    let host = MarkdownWebView.Coordinator(session: session)
    let view = host.makeView()
    defer { host.stop(view) }
    for _ in 0..<300 where !session.ready { try await Task.sleep(for: .milliseconds(20)) }
    #expect(session.ready)
    let edit = """
      for (let i = 0; i < 200; i++) {
        const input = document.querySelector('[contenteditable="true"]');
        if (input) {
          input.focus();
          document.execCommand('insertText', false, 'Synthetic edit ');
          return true;
        }
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      throw Error('Editable document unavailable');
      """
    _ = try await view.callAsyncJavaScript(edit, arguments: [:], in: nil, contentWorld: .page)
    #expect(try await host.snapshot().value.contains("Synthetic edit"))
    _ = try await view.callAsyncJavaScript(
      """
      document.querySelector('button[aria-label="Body options"]').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      document.querySelector('button[aria-label=Undo]').click();
      """, arguments: [:], in: nil,
      contentWorld: .page)
    #expect(
      try await host.snapshot().value.trimmingCharacters(in: .whitespacesAndNewlines)
        == "# First\n\nOriginal")
    // Refill undo history before switching to a different record/property.
    _ = try await view.callAsyncJavaScript(edit, arguments: [:], in: nil, contentWorld: .page)
    #expect(try await host.snapshot().value.contains("Synthetic edit"))
    let firstID = session.document.id
    session.begin(value: "# Second\n\nUnchanged source.\n", label: "Description", readOnly: false)
    host.render()
    _ = try await view.callAsyncJavaScript(
      """
      for (let i = 0; i < 200; i++) {
        const input = document.querySelector('[contenteditable="true"]');
        if (input) {
          document.querySelector('button[aria-label="Description options"]').click();
          await new Promise(resolve => setTimeout(resolve, 0));
          document.querySelector('button[aria-label=Undo]').click();
          return true;
        }
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      throw Error('Replacement document unavailable');
      """, arguments: [:], in: nil, contentWorld: .page)
    let afterUndo = try await host.snapshot()
    #expect(afterUndo.id != firstID)
    #expect(afterUndo.id == session.document.id)
    #expect(afterUndo.value == "# Second\n\nUnchanged source.\n")
  }

  @Test func keepingAndCopyingRecoveredSourceCollectsLiveWebKitWhenChangeDeliveryIsDelayed()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(
      root: root.appendingPathComponent("drafts"),
      workspace: root.appendingPathComponent("local.sqlite"))
    let original: WorkspaceRecord = [
      "id": .string("fixture"), "body": .string("Cached"), "updated_at": .string("revision-1"),
    ]
    let properties: [WorkspaceRecord] = [["col": .string("body"), "type": .string("markdown")]]
    let pending = PendingEditorWrite(
      id: "pending-fixture", patch: ["body": .string("Submitted")], expectedUpdatedAt: "revision-1")
    try store.save(
      StoredEditorDraft(
        table: "notes", recordID: "fixture",
        draft: RecordDraft(properties: properties, original: original), failure: nil,
        failedPatch: nil, pendingWrite: pending))
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "notes", store: store
    ) { _, _ in
      Issue.record("Copy and Keep must not save the row")
      return [:]
    }
    editor.resumeDraft()
    let session = MarkdownEditorSession(value: "Cached", label: "Body")
    session.onChange = { editor.setValue($0, for: "body") }
    let host = MarkdownWebView.Coordinator(session: session)
    let view = host.makeView()
    defer { host.stop(view) }
    for _ in 0..<300 where !session.ready { try await Task.sleep(for: .milliseconds(20)) }
    try #require(session.ready)
    // Hold ordinary IPC delivery in the real island. Its live document still
    // receives input, so relying on the native cache deterministically loses it.
    view.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
    _ = try await view.callAsyncJavaScript(
      """
      document.querySelector('button[aria-label="Body options"]').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      document.querySelector('button[aria-label="Body source"]').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      """, arguments: [:], in: nil, contentWorld: .page)
    for (value, lock) in [("Copied final!", false), ("Kept final!", true)] {
      _ = try await view.callAsyncJavaScript(
        """
        const input = document.querySelector('textarea');
        input.value = value;
        input.dispatchEvent(new Event('input', {bubbles: true}));
        """, arguments: ["value": value], in: nil, contentWorld: .page)
      #expect(session.document.value != value)
      try await editor.keepDraft { try await session.collectSnapshot(lock: lock) }
      #expect(session.document.value == value)
      #expect(try store.all().first?.draft.values["body"] == value)
      #expect(try store.all().first?.pendingWrite?.id == "pending-fixture")
      #expect(editor.needsReview)
    }
  }

  @Test func bundledEditorRoundTripsFinalSourceAndRejectsRemoteNavigation() async throws {
    let session = MarkdownEditorSession(value: "# Fixture\n\nUntouched source.\n", label: "Body")
    var changes: [String] = []
    session.onChange = { changes.append($0) }
    let host = MarkdownWebView.Coordinator(session: session)
    let view = host.makeView()
    defer { host.stop(view) }
    for _ in 0..<300 where !session.ready { try await Task.sleep(for: .milliseconds(20)) }
    #expect(session.ready, Comment(rawValue: session.failure ?? "Editor did not become ready"))
    let first = try await host.snapshot()
    #expect(first.value == session.document.value)
    #expect(changes.isEmpty, "Opening Markdown must not rewrite the stored source")
    let replacement = "# Final source\n\n**Typed** 'quote' \\ path\n"
    _ = try await view.callAsyncJavaScript(
      """
      document.querySelector('button[aria-label="Body options"]').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      const source = document.querySelector('button[aria-label="Body source"]');
      source.click();
      await new Promise(resolve => setTimeout(resolve, 0));
      const input = document.querySelector('textarea');
      input.value = value;
      input.dispatchEvent(new Event('input', {bubbles:true}));
      return true;
      """, arguments: ["value": replacement], in: nil, contentWorld: .page)
    // No debounce or sleep after the final input: Done must read the live document.
    let finish = try #require(session.snapshot)
    try session.acceptSnapshot(try await finish(true))
    #expect(session.document.value == replacement)
    #expect(try await host.snapshot().readOnly, "Done freezes input at the returned snapshot")
    #expect(!MarkdownWebView.Coordinator.allowsNavigation(URL(string: "https://fixture.invalid")))
    #expect(!MarkdownWebView.Coordinator.allowsNavigation(URL(string: "file:///tmp/private")))
    #expect(MarkdownWebView.Coordinator.allowsNavigation(URL(string: "about:blank")))
  }
}
