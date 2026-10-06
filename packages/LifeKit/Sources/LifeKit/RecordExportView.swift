import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class RecordExportPresentation {
  let snapshot: RecordExportSnapshot
  var format = RecordExportFormat.json
  private(set) var preparing = false
  private(set) var metadata: RecordExportFile?
  private(set) var error: String?
  @ObservationIgnored private let serialize:
    @Sendable (RecordExportSnapshot, RecordExportFormat) async throws -> RecordExportArtifact
  @ObservationIgnored private var request = 0
  @ObservationIgnored private var operation: Task<Void, Never>?

  init(
    snapshot: RecordExportSnapshot,
    serialize:
      @escaping @Sendable (RecordExportSnapshot, RecordExportFormat) async throws ->
      RecordExportArtifact = {
        try await RecordExportSerializer().serialize($0, format: $1)
      }
  ) {
    self.snapshot = snapshot
    self.serialize = serialize
  }

  /// Own the action synchronously, before its task can be queued behind dismissal.
  @discardableResult
  func startPreparation(onReady: @escaping (RecordExportFile) -> Void) -> Task<Void, Never>? {
    guard !preparing else { return nil }
    request += 1
    let current = request
    let snapshot = snapshot
    let format = format
    let serialize = serialize
    preparing = true
    error = nil
    let work = Task<Void, Never> { [weak self] in
      guard let self else { return }
      defer {
        if current == self.request {
          self.operation = nil
          self.preparing = false
        }
      }
      do {
        try Task.checkCancellation()
        let artifact = try await serialize(snapshot, format)
        guard current == self.request, !Task.isCancelled else { return }
        self.metadata = artifact.files.count == 2 ? artifact.files[1] : nil
        if let file = artifact.files.first { onReady(file) }
      } catch is CancellationError {
        return
      } catch {
        if current == self.request, !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
    operation = work
    return work
  }

  func cancelPreparation() {
    request += 1
    operation?.cancel()
    operation = nil
    preparing = false
  }

  func saveCompleted(_ result: Result<URL, Error>) {
    if case .failure(let failure) = result,
      (failure as? CocoaError)?.code != .userCancelled
    {
      error = failure.localizedDescription
    } else {
      error = nil
    }
  }
}

struct RecordExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
  let data: Data

  init(file: RecordExportFile) { data = file.data }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// Present from the existing workspace overflow Menu after the host freezes a loaded-row capture.
struct RecordExportView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: RecordExportPresentation
  @State private var document: RecordExportDocument?
  @State private var filename = "records.json"
  @State private var contentType = UTType.json
  @State private var saving = false

  init(snapshot: RecordExportSnapshot) {
    _model = State(initialValue: RecordExportPresentation(snapshot: snapshot))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Table", value: model.snapshot.table)
          LabeledContent("Loaded rows", value: model.snapshot.rows.count.formatted())
        } footer: {
          Text("Table completeness and freshness unknown.")
        }
        Section {
          Picker("Format", selection: $model.format) {
            Text("JSON (exact values)").tag(RecordExportFormat.json)
            Text("CSV (spreadsheet)").tag(RecordExportFormat.csv)
          }.disabled(model.preparing || saving).accessibilityIdentifier("record-export-format")
          Button(model.format == .json ? "Save JSON…" : "Save CSV…") {
            model.startPreparation { save($0) }
          }
          .disabled(model.preparing || saving).accessibilityIdentifier("record-export-save")
          if model.preparing { ProgressView("Preparing export…") }
          if let metadata = model.metadata {
            Button("Save CSV metadata…") { save(metadata) }
              .disabled(model.preparing || saving).accessibilityIdentifier("record-export-metadata")
          }
        } footer: {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "Stored values only. Local edits may not be synced. Attached files are not included.")
            if model.format == .csv {
              Text(
                "CSV can change types in spreadsheets. Save its metadata separately; use JSON for exact values."
              )
            }
          }
        }
        if let error = model.error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("record-export-error")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Export loaded rows")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            model.cancelPreparation()
            dismiss()
          }
          .keyboardShortcut(.cancelAction).disabled(saving)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 380, idealWidth: 440, minHeight: 360)
    #endif
    .fileExporter(
      isPresented: $saving, document: document, contentType: contentType,
      defaultFilename: filename
    ) { result in
      model.saveCompleted(result)
      document = nil
    }
    .onDisappear { model.cancelPreparation() }
  }

  private func save(_ file: RecordExportFile) {
    document = RecordExportDocument(file: file)
    filename = file.filename
    contentType = file.mimeType.hasPrefix("text/csv") ? .commaSeparatedText : .json
    saving = true
  }
}
