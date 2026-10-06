import QuickLook
import SwiftUI

#if os(iOS)
  import UIKit
#endif

struct MarkdownEditorScreen: View {
  @Binding var value: String
  let label: String
  let editor: RecordEditorModel
  let undoAction: CoreUndoAction?
  let undo: ((CoreUndoAction) async throws -> WorkspaceRecord)?
  let isCurrent: @MainActor () -> Bool
  let resolveFile: ((String) async throws -> RetainedFile)?
  let openSourceLink: ((String) async throws -> Bool)?
  @State private var previewFile: RetainedFile?
  @State private var previewURL: URL?
  @Environment(\.openURL) private var openURL
  @State private var session: MarkdownEditorSession
  @State private var nativeSource = false
  @State private var finishing = false
  @State private var copied = false
  @State private var finishFailure: String?
  @State private var backgroundFlush: Task<Void, Never>?
  #if os(iOS)
    @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  #endif
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  init(
    value: Binding<String>, label: String, editor: RecordEditorModel,
    undoAction: CoreUndoAction? = nil,
    undo: ((CoreUndoAction) async throws -> WorkspaceRecord)? = nil,
    isCurrent: @escaping @MainActor () -> Bool = { true },
    resolveFile: ((String) async throws -> RetainedFile)? = nil,
    openSourceLink: ((String) async throws -> Bool)? = nil
  ) {
    _value = value
    self.label = label
    self.editor = editor
    self.undoAction = undoAction
    self.undo = undo
    self.isCurrent = isCurrent
    self.resolveFile = resolveFile
    self.openSourceLink = openSourceLink
    _session = State(initialValue: MarkdownEditorSession(value: value.wrappedValue, label: label))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(finishFailure ?? editor.status)
          .font(.caption).foregroundStyle(editor.failure == nil ? Color.secondary : Color.red)
          .accessibilityIdentifier("markdown-save-status")
        if editor.failure != nil && !editor.isNew && !editor.needsReview && !editor.autosavePaused
          && !editor.isTrashed
        {
          Button("Retry") { finish(retry: true, close: false) }.disabled(finishing || editor.saving)
        }
      }.padding(.horizontal)
      if let action = undoAction, let undo {
        Button {
          finishing = true
          finishFailure = nil
          Task {
            do {
              try await editor.performUndo(
                action, isCurrent: isCurrent, collect: { try await collect(lock: true) }
              ) {
                try await undo(action)
              }
              if session.document.value != value || session.document.readOnly != editor.isTrashed {
                session.begin(value: value, label: label, readOnly: editor.isTrashed)
              }
            } catch { finishFailure = error.localizedDescription }
            session.resumeEditing?()
            finishing = false
          }
        } label: {
          Label("Undo last saved change", systemImage: "arrow.uturn.backward")
        }
        .disabled(finishing || editor.saving || editor.needsReview)
        .accessibilityIdentifier("undo-markdown").padding(.horizontal)
      }
      if editor.failure != nil || finishFailure != nil || editor.autosavePaused {
        VStack(alignment: .leading, spacing: 8) {
          if editor.needsReview {
            Text(
              "Copy your source, then open the saved record to review and paste it. Your draft will remain available."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Button {
              retainSource(close: false)
            } label: {
              Label(
                copied ? "Copied" : "Copy Markdown",
                systemImage: copied ? "checkmark" : "doc.on.doc")
            }.accessibilityLabel("Copy Markdown")
            Spacer()
            Button("Keep draft and close") { retainSource(close: true) }
              .accessibilityIdentifier("keep-markdown-draft")
          }
        }.padding(.horizontal)
      }
      if let failure = session.failure {
        Text(failure).font(.callout).foregroundStyle(.secondary).padding(.horizontal)
      }
      ZStack {
        MarkdownWebView(session: session)
          .opacity(session.ready && !nativeSource ? 1 : 0)
          .allowsHitTesting(session.ready && !nativeSource && !finishing)
          .accessibilityHidden(!session.ready || nativeSource)
        if nativeSource || session.failure != nil {
          VStack(alignment: .leading) {
            Text("Markdown source").font(.caption).foregroundStyle(.secondary)
            TextEditor(
              text: Binding(
                get: { session.document.value },
                set: {
                  nativeSource = true
                  session.editSource($0)
                })
            )
            .font(.system(.body, design: .monospaced)).disabled(editor.isTrashed)
            .accessibilityLabel("\(label) Markdown source")
            .accessibilityIdentifier("markdown-source-fallback")
          }.padding()
        } else if !session.ready {
          VStack(spacing: 12) {
            ProgressView("Loading editor…")
            Button("Use source editor") { nativeSource = true }
          }
        }
      }
    }
    .navigationTitle(label)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { finish(retry: false, close: true) }
          .disabled(finishing).accessibilityIdentifier("finish-markdown")
      }
    }
    .disabled(finishing)
    .quickLookPreview($previewURL)
    .onChange(of: previewURL) { _, url in
      if url == nil {
        previewFile?.dispose()
        previewFile = nil
      }
    }
    .onAppear {
      session.onChange = { value = $0 }
      session.begin(value: value, label: label, readOnly: editor.isTrashed)
      session.resolveFile = resolveFile
      session.openExternal = { openURL($0) }
      session.openLink = { href in
        guard let openSourceLink, isCurrent(), !finishing else { return false }
        finishing = true
        defer {
          finishing = false
          session.resumeEditing?()
        }
        try await collect(lock: true)
        try await editor.flushMarkdown()
        guard !editor.dirty, !editor.needsReview else {
          throw WorkspaceError(
            message:
              "Save the other record changes before opening this link. Your draft has been kept.",
            violations: [])
        }
        return try await openSourceLink(href)
      }
      session.openFile = { key in
        guard let resolveFile else {
          throw WorkspaceError(message: "Connect to your hub to open this file.", violations: [])
        }
        let file = try await resolveFile(key)
        guard isCurrent() else {
          file.dispose()
          return
        }
        previewFile?.dispose()
        previewFile = file
        previewURL = file.url
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .inactive { flushInBackground() }
    }
    .onChange(of: session.document.value) { _, _ in copied = false }
    .onDisappear {
      session.invalidate()
      previewFile?.dispose()
      previewFile = nil
    }
  }

  private func collect(lock: Bool) async throws {
    if session.ready && !nativeSource {
      do { try await session.collectSnapshot(lock: lock) } catch {
        session.fail("The editor is unavailable. Your last received source is below.")
        throw error
      }
    }
  }

  private func finish(retry: Bool, close: Bool) {
    finishing = true
    finishFailure = nil
    Task {
      do {
        try await collect(lock: close)
        if editor.autosavePaused || editor.isTrashed {
          try editor.keepDraft()
        } else {
          try await editor.flushMarkdown(retry: retry)
        }
        if close { dismiss() }
      } catch {
        finishFailure = error.localizedDescription
        session.resumeEditing?()
      }
      finishing = false
    }
  }

  private func retainSource(close: Bool) {
    finishing = true
    finishFailure = nil
    Task {
      do {
        try await editor.keepDraft { try await collect(lock: close) }
        if close {
          dismiss()
        } else {
          CopyDraftButton.copy(session.document.value)
          copied = true
        }
      } catch {
        finishFailure = error.localizedDescription
        session.resumeEditing?()
      }
      finishing = false
    }
  }

  private func flushInBackground() {
    guard backgroundFlush == nil, !finishing else { return }
    #if os(iOS)
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save draft") {
        Task { @MainActor in
          backgroundFlush?.cancel()
          endBackgroundTime()
        }
      }
    #endif
    backgroundFlush = Task {
      defer {
        endBackgroundTime()
        backgroundFlush = nil
      }
      do {
        try await collect(lock: false)
        try Task.checkCancellation()
        try await editor.flushMarkdown()
      } catch {
        // Every delivered edit is already journaled. A failed or expired flush
        // leaves it recoverable without pretending that the row was saved.
        if !(error is CancellationError) { finishFailure = error.localizedDescription }
      }
    }
  }

  private func endBackgroundTime() {
    #if os(iOS)
      if backgroundTask != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
      }
    #endif
  }
}
