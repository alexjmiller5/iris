import Observation
import QuickLook
import SwiftUI
import WebKit

/// The prepared record owns the live WebKit document, including input whose
/// change notification has not arrived yet. Table view recycling is not a close.
@Observable @MainActor final class InlineMarkdownEditor {
  let fieldID: String
  let session: MarkdownEditorSession
  var usingSource = false
  var previewURL: URL?
  @ObservationIgnored private var previewFile: RetainedFile?

  func configureFileActions(
    resolveFile: @escaping (String) async throws -> RetainedFile,
    isCurrent: @escaping () -> Bool
  ) {
    guard session.isActive else { return }
    session.openFile = { [weak self] key in
      guard let self, session.isActive, isCurrent(), !Task.isCancelled else { return }
      let documentID = session.document.id
      let file = try await resolveFile(key)
      guard session.isActive, session.document.id == documentID, isCurrent(), !Task.isCancelled
      else {
        file.dispose()
        return
      }
      dismissPreview()
      previewFile = file
      previewURL = file.url
    }
  }

  func dismissPreview() {
    previewFile?.dispose()
    previewFile = nil
    previewURL = nil
  }
  @ObservationIgnored let coordinator: MarkdownWebView.Coordinator
  @ObservationIgnored let webView: WKWebView

  init(field: CatalogField, value: String, onChange: @escaping (String) -> Void) {
    fieldID = field.id
    let session = MarkdownEditorSession(value: value, label: field.label)
    session.onChange = onChange
    self.session = session
    let coordinator = MarkdownWebView.Coordinator(session: session)
    self.coordinator = coordinator
    webView = coordinator.makeView()
  }

  isolated deinit { coordinator.stop(webView) }

  func collect(lock: Bool) async throws {
    guard session.ready, !usingSource else { return }
    do { try await session.collectSnapshot(lock: lock) } catch {
      session.fail("The editor is unavailable. Your last received source is below.")
      usingSource = true
      throw error
    }
  }

  func stop() {
    dismissPreview()
    coordinator.stop(webView)
  }
}

struct InlineMarkdownField: View {
  @Bindable var editor: InlineMarkdownEditor
  var height: CGFloat = 240
  private var session: MarkdownEditorSession { editor.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let failure = session.failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
      ZStack {
        RetainedMarkdownWebView(editor: editor)
          .opacity(session.ready && !editor.usingSource ? 1 : 0)
          .allowsHitTesting(session.ready && !editor.usingSource)
          .accessibilityHidden(!session.ready || editor.usingSource)
        if editor.usingSource || session.failure != nil {
          TextEditor(
            text: Binding(
              get: { session.document.value },
              set: {
                editor.usingSource = true
                session.editSource($0)
              }
            )
          )
          .font(.system(.body, design: .monospaced))
          .accessibilityLabel("\(session.document.label) Markdown source")
          .accessibilityIdentifier("inline-markdown-source")
        } else if !session.ready {
          VStack(spacing: 8) {
            ProgressView("Loading editor…")
            Button("Use source editor") { editor.usingSource = true }
          }
        }
      }.frame(height: height)
    }
    .quickLookPreview($editor.previewURL)
    .onChange(of: editor.previewURL) { _, url in
      if url == nil { editor.dismissPreview() }
    }
  }
}

private struct RetainedMarkdownWebView {
  let editor: InlineMarkdownEditor
}

#if os(macOS)
  extension RetainedMarkdownWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { editor.webView }
    func updateNSView(_ view: WKWebView, context: Context) { editor.coordinator.render() }
  }
#else
  extension RetainedMarkdownWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { editor.webView }
    func updateUIView(_ view: WKWebView, context: Context) { editor.coordinator.render() }
  }
#endif
