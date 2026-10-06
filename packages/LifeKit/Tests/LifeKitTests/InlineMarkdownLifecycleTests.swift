#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import WebKit

  @testable import LifeKit

  @Suite(.serialized) @MainActor
  struct InlineMarkdownLifecycleTests {
    @Test func backgroundRowsDoNotReplaceTheLiveEditorOrLoseUndeliveredTyping() async throws {
      let field = CatalogField(property: ["col": .string("body"), "type": .string("markdown")])
      let editor = InlineMarkdownEditor(field: field, value: "Original", onChange: { _ in })
      let session = editor.session
      defer { editor.stop() }
      let row = WorkspaceRow(
        record: ["id": .string("one"), "body": .string("Original")], label: "One")
      let ticket = UUID()
      func grid(_ rows: [WorkspaceRow], extraColumn: Bool = true) -> MacRecordTable<
        InlineMarkdownField
      > {
        MacRecordTable(
          rows: rows,
          columns: [NativeGridColumn(field: field, width: 360)]
            + (extraColumn
              ? [
                NativeGridColumn(
                  field: CatalogField(property: ["col": .string("status")]), width: 100)
              ] : []),
          titleField: nil,
          editingRow: row.byteExactID, editingColumn: "body", editorID: ticket,
          actionsEnabled: false, onOpen: { _ in }, onEdit: { _, _ in }, onSort: { _, _ in },
          onFilter: { _ in }
        ) { InlineMarkdownField(editor: editor) }
      }
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 120, y: 120, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: grid([row]))
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      for _ in 0..<500
      where !session.ready || !descendants(host).contains(where: { $0 is WKWebView }) {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(session.ready)
      let view = try #require(descendants(host).compactMap { $0 as? WKWebView }.first)
      view.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
      _ = try await view.callAsyncJavaScript(
        """
        for (let i = 0; i < 300; i++) {
          const input = document.querySelector('[contenteditable="true"]');
          if (input) {
            input.focus();
            document.execCommand('selectAll');
            document.execCommand('insertText', false, 'Undelivered final input!');
            return true;
          }
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        throw Error('Editor not ready');
        """, arguments: [:], in: nil, contentWorld: .page)
      #expect(session.document.value == "Original")
      let updated =
        [WorkspaceRow(record: ["id": .string("new")], label: "New"), row]
        + (0..<100).map { WorkspaceRow(record: ["id": .string("other-\($0)")], label: "Other") }
      host.rootView = grid(updated, extraColumn: false)
      try await Task.sleep(for: .milliseconds(150))
      let retained = try #require(descendants(host).compactMap { $0 as? WKWebView }.first)
      #expect(retained === view, "A background refresh must retain the live cell editor")
      let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
      table.scrollRowToVisible(101)
      try await Task.sleep(for: .milliseconds(100))
      table.scrollRowToVisible(1)
      try await Task.sleep(for: .milliseconds(100))
      #expect(descendants(host).compactMap { $0 as? WKWebView }.first === view)
      try await session.collectSnapshot(lock: true)
      #expect(session.document.value.contains("Undelivered final input!"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
  }
#endif
