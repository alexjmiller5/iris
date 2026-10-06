import Foundation
import Observation

/// Owns one immutable attempt. This model does not activate a viewer or navigate the host.
@Observable @MainActor
final class PageCapturePresentation {
  let attempt: PageCapture
  private(set) var kind = PageCapture.Kind.png
  private(set) var file: RetainedFile?
  private(set) var isLoading = false
  private(set) var unavailableReason: String?
  private(set) var error: String?
  @ObservationIgnored private let fetch: @Sendable (String, Int) async throws -> RetainedFile
  @ObservationIgnored private var request = 0
  @ObservationIgnored private var operation: Task<RetainedFile, Error>?

  init(attempt: PageCapture, fetch: @escaping @Sendable (String, Int) async throws -> RetainedFile) {
    self.attempt = attempt
    self.fetch = fetch
  }

  func prepare(_ kind: PageCapture.Kind, maximumBytes: Int) async {
    cancel()
    let current = request
    self.kind = kind
    isLoading = true
    unavailableReason = nil
    error = nil
    let attempt = attempt
    let fetch = fetch
    let work = Task { try await attempt.loadArtifact(kind, maximumBytes: maximumBytes, fetch: fetch) }
    operation = work
    defer {
      if current == request {
        operation = nil
        isLoading = false
      }
    }
    do {
      let received = try await withTaskCancellationHandler {
        try await work.value
      } onCancel: {
        work.cancel()
      }
      guard current == request, !Task.isCancelled else {
        received.dispose()
        return
      }
      file = received
    } catch {
      guard current == request, !Task.isCancelled, !(error is CancellationError) else { return }
      if let failure = error as? PageCaptureError,
        failure == .previewUnavailable || failure == .artifactUnavailable
      {
        unavailableReason = failure.localizedDescription
      } else {
        self.error = (error as? PageCaptureError)?.localizedDescription
          ?? "File request failed. Check your connection and file access, then retry."
      }
    }
  }

  func cancel() {
    request += 1
    operation?.cancel()
    operation = nil
    file?.dispose()
    file = nil
    isLoading = false
  }
}
