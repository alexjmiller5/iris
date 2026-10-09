import Foundation

struct PendingNativeLink {
  struct Request: Identifiable {
    let id = UUID()
    let link: NativeDeepLink
  }
  private(set) var request: Request?
  private(set) var error: String?
  func requestToOpen(allowed: Bool) -> Request? { allowed ? request : nil }

  mutating func receive(_ url: URL) {
    do {
      let link = try NativeDeepLink(url: url)
      request = Request(link: link)
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  mutating func dismiss() {
    request = nil
    error = nil
  }

  mutating func complete(_ id: UUID) {
    guard request?.id == id else { return }
    dismiss()
  }

  mutating func fail(_ id: UUID, message: String) {
    guard request?.id == id else { return }
    error = message
  }
}
