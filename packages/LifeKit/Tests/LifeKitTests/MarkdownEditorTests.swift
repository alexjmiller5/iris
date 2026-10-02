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
      const source = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Source');
      source.click();
      await new Promise(resolve => setTimeout(resolve, 0));
      const input = document.querySelector('textarea');
      input.value = value;
      input.dispatchEvent(new Event('input', {bubbles:true}));
      return true;
      """, arguments: ["value": replacement], in: nil, contentWorld: .page)
    // No debounce or sleep after the final input: Done must read the live document.
    let finish = try #require(session.snapshot)
    try session.acceptSnapshot(try await finish())
    #expect(session.document.value == replacement)
    #expect(try await host.snapshot().readOnly, "Done freezes input at the returned snapshot")
    #expect(!MarkdownWebView.Coordinator.allowsNavigation(URL(string: "https://fixture.invalid")))
    #expect(!MarkdownWebView.Coordinator.allowsNavigation(URL(string: "file:///tmp/private")))
    #expect(MarkdownWebView.Coordinator.allowsNavigation(URL(string: "about:blank")))
  }
}
