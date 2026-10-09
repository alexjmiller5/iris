import Testing

@testable import IrisKit

@MainActor struct MarkdownSnapshotTests {
  @Test func lockingSnapshotWinsOverAnIntermediateDelayedChange() async throws {
    let session = MarkdownEditorSession(value: "Before", label: "Content")
    session.snapshot = { lock in
      #expect(lock)
      session.receive(["type": "change", "id": session.document.id, "value": "Intermediate"])
      return MarkdownDocument(
        id: session.document.id, value: "Final!", label: "Content", readOnly: false)
    }
    try await session.collectSnapshot(lock: true)
    #expect(session.document.value == "Final!")
  }
}
