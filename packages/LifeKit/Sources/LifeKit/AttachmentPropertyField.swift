import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentPropertyField: View {
  @Binding var value: String
  let label: String
  let attachments: AttachmentController?
  let isCurrent: () -> Bool
  let resolve: (String) async throws -> RetainedFile
  @State private var importing = false
  @State private var busy = false
  @State private var failure: String?
  @State private var previewURL: URL?
  @State private var previewFile: RetainedFile?

  private var key: String? {
    guard value.hasPrefix("/v1/files/") else { return nil }
    let key = String(value.dropFirst(10))
    guard let canonical = try? retainedFileRoute(key: key), canonical == value else { return nil }
    return key
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(label, text: $value).accessibilityLabel(label)
      HStack {
        if attachments != nil {
          Button("Attach file", systemImage: "paperclip") { importing = true }
            .disabled(busy).accessibilityIdentifier("property-attach-file")
        }
        if let key {
          Button("Open file", systemImage: "doc") {
            busy = true
            let selected = value
            Task { @MainActor in
              defer { busy = false }
              do {
                let file = try await resolve(key)
                guard isCurrent(), selected.utf8.elementsEqual(value.utf8) else {
                  file.dispose()
                  return
                }
                previewFile?.dispose()
                previewFile = file
                previewURL = file.url
              } catch {
                failure =
                  "The file could not open. Its reference has been kept. Retry when connected."
              }
            }
          }.disabled(busy)
        }
      }
      if let attachments,
        let entry = attachments.entries.first(where: { $0.key == key }), entry.state != .uploaded
      {
        Text(
          entry.state == .failed
            ? "Upload failed. Bytes kept on this device." : "Kept on this device; upload pending."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Retry upload") { attachments.retry() }.disabled(
          attachments.busy || attachments.upload == nil)
      }
      if let message = failure ?? attachments?.error {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      guard case .success(let url) = result, let attachments, isCurrent(), !busy else { return }
      busy = true
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
          if scoped { url.stopAccessingSecurityScopedResource() }
          busy = false
        }
        do {
          let entry = try await attachments.stage(
            url, name: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
              ?? "application/octet-stream")
          guard isCurrent() else { return }
          value = entry.reference
          failure = nil
        } catch { failure = "The file could not be kept. Check its size and storage, then retry." }
      }
    }
    .quickLookPreview($previewURL)
    .onChange(of: previewURL) { _, url in
      if url == nil {
        previewFile?.dispose()
        previewFile = nil
      }
    }
    .onDisappear {
      previewFile?.dispose()
      previewFile = nil
    }
  }
}
