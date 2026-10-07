import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Owns one immutable attempt. This model does not activate a viewer or navigate the host.
@Observable @MainActor
final class PageCapturePresentation: Identifiable {
  let id = UUID()
  let attempt: PageCapture
  private(set) var kind = PageCapture.Kind.png
  private(set) var file: RetainedFile?
  private(set) var isLoading = false
  private(set) var unavailableReason: String?
  private(set) var error: String?
  private(set) var previewData: Data?
  private(set) var isSaving = false
  @ObservationIgnored private let fetch: @Sendable (String, Int) async throws -> RetainedFile
  @ObservationIgnored private var request = 0
  @ObservationIgnored private var operation: Task<Void, Never>?

  init(attempt: PageCapture, fetch: @escaping @Sendable (String, Int) async throws -> RetainedFile)
  {
    self.attempt = attempt
    self.fetch = fetch
  }

  @discardableResult
  func startPreview() -> Task<Void, Never>? {
    guard !isLoading, !isSaving, !Task.isCancelled else { return nil }
    return start(.png, maximumBytes: PageCapture.previewLimit, preview: true)
  }

  @discardableResult
  func startSave(_ kind: PageCapture.Kind, onReady: @escaping (PageCaptureDocument) -> Void)
    -> Task<Void, Never>?
  {
    guard !isLoading, !isSaving, !Task.isCancelled else { return nil }
    return start(kind, maximumBytes: PageCapture.downloadLimit, onReady: onReady)
  }

  func saveCompleted(_ result: Result<URL, Error>) {
    isSaving = false
    if case .failure(let failure) = result,
      (failure as? CocoaError)?.code != .userCancelled
    {
      error = failure.localizedDescription
    } else {
      error = nil
    }
  }

  func saveDismissed() { isSaving = false }

  func prepare(_ kind: PageCapture.Kind, maximumBytes: Int) async {
    guard !Task.isCancelled, !isSaving else { return }
    let work = start(kind, maximumBytes: maximumBytes)
    await withTaskCancellationHandler {
      await work.value
    } onCancel: {
      work.cancel()
    }
  }

  /// Claim the action before scheduling its task, so a queued action cannot
  /// restart after dismissal. Every publication is tied to this request.
  private func start(
    _ kind: PageCapture.Kind, maximumBytes: Int, preview: Bool = false,
    onReady: ((PageCaptureDocument) -> Void)? = nil
  ) -> Task<Void, Never> {
    let previousPreview = previewData
    cancel()
    if onReady != nil { previewData = previousPreview }
    let current = request
    self.kind = kind
    isLoading = true
    unavailableReason = nil
    error = nil
    let attempt = attempt
    let fetch = fetch
    let work = Task<Void, Never> { [weak self] in
      guard let self else { return }
      defer {
        if current == self.request {
          self.operation = nil
          self.isLoading = false
        }
      }
      do {
        try Task.checkCancellation()
        let received = try await attempt.loadArtifact(
          kind, maximumBytes: maximumBytes, fetch: fetch)
        guard current == self.request, !Task.isCancelled else {
          received.dispose()
          return
        }
        self.file = received
        if preview {
          do {
            let data = try await received.imagePreview()
            guard current == self.request, !Task.isCancelled else { return }
            self.previewData = data
          } catch {
            guard current == self.request, !Task.isCancelled, !(error is CancellationError) else {
              return
            }
            self.unavailableReason =
              "Preview is unavailable on this device. You can still save the original PNG."
          }
        } else if let onReady {
          let read = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data = try Data(contentsOf: received.url, options: .mappedIfSafe)
            try Task.checkCancellation()
            return data
          }
          let data = try await withTaskCancellationHandler {
            try await read.value
          } onCancel: {
            read.cancel()
          }
          guard current == self.request, !Task.isCancelled else { return }
          self.isSaving = true
          onReady(PageCaptureDocument(data: data, kind: kind))
        }
      } catch {
        guard current == self.request, !Task.isCancelled, !(error is CancellationError) else {
          return
        }
        if let failure = error as? PageCaptureError,
          failure == .previewUnavailable || failure == .artifactUnavailable
        {
          self.unavailableReason = failure.localizedDescription
        } else {
          self.error =
            (error as? PageCaptureError)?.localizedDescription
            ?? "File request failed. Check your connection and file access, then retry."
        }
      }
    }
    operation = work
    return work
  }

  func cancel() {
    request += 1
    operation?.cancel()
    operation = nil
    file?.dispose()
    file = nil
    previewData = nil
    isLoading = false
    isSaving = false
  }
}

struct PageCaptureDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.png, .html] }
  let data: Data
  let kind: PageCapture.Kind
  init(data: Data, kind: PageCapture.Kind) {
    self.data = data
    self.kind = kind
  }
  init(configuration: ReadConfiguration) throws {
    guard let bytes = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = bytes
    kind = configuration.contentType == .png ? .png : .html
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct PageCaptureView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let model: PageCapturePresentation
  @State private var document: PageCaptureDocument?
  @State private var saving = false
  @State private var retrySave: PageCapture.Kind?

  var body: some View {
    NavigationStack {
      Form {
        PageCaptureDetails(attempt: model.attempt)
        if model.attempt.status == .succeeded || model.attempt.status == .partial {
          Section("Preview") {
            if let data = model.previewData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            {
              Image(decorative: image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 480)
                .accessibilityLabel("Captured page screenshot")
                .accessibilityAddTraits(.isImage).accessibilityIdentifier("capture-preview")
            }
            if model.isLoading { ProgressView("Preparing capture…") }
            if let reason = model.unavailableReason {
              Text(reason).foregroundStyle(.secondary).accessibilityIdentifier(
                "capture-unavailable")
            }
          }
          Section {
            Button("Save PNG…") { save(.png) }
              .disabled(!model.attempt.canDownload(.png) || model.isLoading || model.isSaving)
              .accessibilityIdentifier("capture-save-png")
            Button("Save HTML…") { save(.html) }
              .disabled(!model.attempt.canDownload(.html) || model.isLoading || model.isSaving)
              .accessibilityIdentifier("capture-save-html")
          } footer: {
            if !model.attempt.canDownload(.png) || !model.attempt.canDownload(.html) {
              Text(
                "Files larger than 128 MiB cannot be saved by this client. The retained capture is unchanged."
              )
            }
          }
        }
        if let error = model.error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("capture-error")
            Button("Retry") {
              if let retrySave { save(retrySave) } else { model.startPreview() }
            }.disabled(model.isLoading || model.isSaving).accessibilityIdentifier("capture-retry")
          }
        }
        if let url = model.attempt.sourceURL {
          Section {
            Button("Open original website") { openURL(url) }
              .accessibilityIdentifier("capture-open-original")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Page capture")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            model.cancel()
            dismiss()
          }
          .keyboardShortcut(.cancelAction).disabled(model.isSaving)
          .accessibilityIdentifier("capture-done")
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, idealWidth: 640, minHeight: 520, idealHeight: 760)
    #endif
    .fileExporter(
      isPresented: $saving, document: document,
      contentType: document?.kind == .png ? .png : .html,
      defaultFilename: document?.kind == .png ? "page.png" : "page.html"
    ) { result in
      model.saveCompleted(result)
      document = nil
    }
    .onChange(of: saving) { _, presented in
      if !presented {
        model.saveDismissed()
        document = nil
      }
    }
    .interactiveDismissDisabled(model.isSaving)
    .task {
      if model.attempt.status == .succeeded || model.attempt.status == .partial {
        await model.startPreview()?.value
      }
    }
    .onDisappear { model.cancel() }
  }

  private func save(_ kind: PageCapture.Kind) {
    retrySave = kind
    model.startSave(kind) {
      document = $0
      saving = true
    }
  }
}

private struct PageCaptureDetails: View {
  let attempt: PageCapture
  var body: some View {
    Section {
      LabeledContent("Status", value: attempt.status.rawValue.capitalized)
      LabeledContent("Attempted", value: attempt.attemptedAt)
      if let capturedAt = attempt.capturedAt { LabeledContent("Captured", value: capturedAt) }
      Text(attempt.originalURL).textSelection(.enabled).accessibilityIdentifier(
        "capture-original-text")
      if let warning = attempt.warning {
        Text(warning.message).foregroundStyle(.secondary).accessibilityIdentifier("capture-warning")
      } else if let failure = attempt.failureDetail ?? attempt.failureCode {
        Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("capture-failure")
      }
      DisclosureGroup("Attempt details") {
        LabeledContent("Attempt ID", value: attempt.id).textSelection(.enabled)
        LabeledContent("Source table", value: attempt.sourceTable)
        LabeledContent("Source record", value: attempt.sourceRowID).textSelection(.enabled)
        LabeledContent("Source property", value: attempt.sourceColumn)
      }
    }
  }
}
