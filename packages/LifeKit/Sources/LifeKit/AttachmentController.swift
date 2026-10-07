import Foundation
import Observation

func attachmentMarkdown(_ entry: StagedAttachment, source: String) -> String {
  let name = entry.name.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
  let image = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(entry.contentType)
  return source + (source.isEmpty ? "" : "\n\n") + (image ? "!" : "")
    + "[" + name + "](<" + entry.reference + ">)"
}

@Observable @MainActor final class AttachmentController {
  private(set) var entries: [StagedAttachment] = []
  private(set) var busy = false
  private(set) var error: String?
  let store: AttachmentStore
  var upload: (@Sendable (StagedAttachment, URL) async throws -> AttachmentReceipt)?
  private var task: Task<Void, Never>?
  private var active = true
  private var request = UUID()
  init(store: AttachmentStore) { self.store = store }

  func stage(_ source: URL, name: String, contentType: String) async throws -> StagedAttachment {
    guard active, !Task.isCancelled else { throw CancellationError() }
    let entry = try await store.stage(source: source, name: name, contentType: contentType)
    guard active, !Task.isCancelled else { throw CancellationError() }
    try await refresh()
    retry()
    return entry
  }
  func refresh() async throws {
    guard active else { throw CancellationError() }
    do {
      let loaded = try await store.entries()
      guard active, !Task.isCancelled else { throw CancellationError() }
      entries = loaded
    } catch {
      if active, !(error is CancellationError) {
        self.error = "The attachment outbox could not be read or saved. Its files have been kept."
      }
      throw error
    }
  }

  func retry() {
    guard active, !busy, let upload else { return }
    let request = UUID()
    self.request = request
    busy = true
    error = nil
    task = Task { [weak self, store] in
      do {
        try await store.uploadPending(upload: upload)
        let entries = try await store.entries()
        guard let self, self.request == request else { return }
        self.entries = entries
        if entries.contains(where: { $0.state == .failed }) {
          self.error =
            "Some files could not upload. Their bytes are kept on this device. Retry when connected."
        }
      } catch {
        guard let self, self.request == request else { return }
        self.error = "The attachment outbox could not be read or saved. Its files have been kept."
      }
      guard let self, self.request == request else { return }
      self.busy = false
      self.task = nil
    }
  }

  func stop() {
    active = false
    request = UUID()
    task?.cancel()
    task = nil
    busy = false
    upload = nil
  }
}
