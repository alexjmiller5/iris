import Observation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The prepared record owns the live WebKit document, including input whose
/// change notification has not arrived yet. Table view recycling is not a close.
@Observable @MainActor final class InlineMarkdownEditor {
  let fieldID: String
  let session: MarkdownEditorSession
  var usingSource = false
  var previewURL: URL?
  var attachments: AttachmentController?
  var attachmentsAreCurrent: () -> Bool = { false }
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
  @State private var importingAttachment = false
  @State private var stagingAttachment = false
  @State private var attachmentError: String?
  private var session: MarkdownEditorSession { editor.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let attachments = editor.attachments, !session.document.readOnly {
        HStack {
          Button("Attach file", systemImage: "paperclip") { importingAttachment = true }
            .disabled(stagingAttachment)
            .accessibilityIdentifier("markdown-attach-file")
          if stagingAttachment { ProgressView("Keeping file on this device…") }
          let pending = attachments.entries.filter { $0.state != .uploaded }
          if !pending.isEmpty {
            Text("\(pending.count) file(s) pending").font(.caption).foregroundStyle(.secondary)
            Button("Retry uploads") { attachments.retry() }.disabled(attachments.busy || attachments.upload == nil)
          }
        }
        if let error = attachmentError ?? attachments.error {
          Text(error).font(.caption).foregroundStyle(.secondary)
        }
      }

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
    .fileImporter(isPresented: $importingAttachment, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result {
        attach(url)
      } else if case .failure = result {
        attachmentError = "The file could not be selected. Try again."
      }
    }
    .quickLookPreview($editor.previewURL)
    .onChange(of: editor.previewURL) { _, url in
      if url == nil { editor.dismissPreview() }
    }
  }
  private func attach(_ url: URL) {
    guard let attachments = editor.attachments, !stagingAttachment, session.isActive,
      !session.document.readOnly, editor.attachmentsAreCurrent()
    else { return }
    stagingAttachment = true
    attachmentError = nil
    let documentID = session.document.id
    Task { @MainActor in
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
        stagingAttachment = false
        session.resumeEditing?()
      }
      do {
        try await editor.collect(lock: true)
        let entry = try await attachments.stage(
          url, name: url.lastPathComponent,
          contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream")
        guard session.isActive, session.document.id == documentID,
          editor.attachments === attachments, editor.attachmentsAreCurrent()
        else { return }
        let source = attachmentMarkdown(entry, source: session.document.value)
        session.editSource(source)
        session.begin(value: source, label: session.document.label, readOnly: false)
        editor.coordinator.render()
      } catch {
        attachmentError =
          "The file could not be kept. Check its size and available storage, then retry."
      }
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
