#if os(macOS)
  import AppKit
  import CryptoKit
  import SwiftUI
  import Testing

  @testable import LifeKit

  /// Opt-in system save-panel acceptance. The driver uses this process's own
  /// synthetic window; ordinary CI never waits for desktop interaction.
  @Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CAPTURE_SAVE"] == "1"))
  @MainActor
  struct PageCaptureNativeAcceptanceTests {
    @Test func saveCancelRetryAndReadback() async throws {
      try #require(
        Bundle.main.bundleURL.pathExtension == "app",
        "Run system-panel acceptance in the application-hosted LifeUITests target.")
      let png = try capturePNGBytes()
      let html = Data(
        "<!doctype html><meta charset=utf-8><p>Capture fixture: 日本語 e\u{301}</p>".utf8)
      var row = try captureRecord()
      for (kind, bytes) in [("png", png), ("html", html)] {
        row[kind + "_bytes"] = .number(Double(bytes.count))
        row[kind + "_sha256"] = .string(
          SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      }
      row["status"] = .string("partial")
      row["failure_code"] = .string("partial")
      row["failure_detail"] = .string(
        "Incomplete archive: 2 resource requests could not be saved; 1 section was still loading.")
      let model = PageCapturePresentation(attempt: try PageCapture(record: row)) { key, _ in
        let image = key.hasSuffix("page.png")
        return try RetainedFile(
          data: image ? png : html,
          contentType: image ? "image/png" : "text/html", name: image ? "page.png" : "page.html")
      }
      _ = NSApplication.shared
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 760, height: 850),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Capture acceptance"
      var finished = false
      window.contentView = NSHostingView(
        rootView: CaptureAcceptanceHost(model: model) { finished = true })
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      defer {
        model.cancel()
        window.close()
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(120))
      var announcedWindow = false
      while !finished && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        if !announcedWindow, model.previewData != nil, let sheet = window.attachedSheet {
          FileHandle.standardError.write(
            Data("CAPTURE_ACCEPTANCE_WINDOW=\(sheet.windowNumber)\n".utf8))
          announcedWindow = true
        }
      }
      try #require(finished, "Complete the synthetic Save/cancel/retry flow and close its sheet.")
      let directory = URL(
        fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIFE_UI_CAPTURE_OUTPUT"])
      )
      #expect(try Data(contentsOf: directory.appendingPathComponent("page.png")) == png)
      #expect(try Data(contentsOf: directory.appendingPathComponent("page.html")) == html)
      #expect(!model.isLoading && !model.isSaving && model.file == nil)
    }
  }

  private struct CaptureAcceptanceHost: View {
    let model: PageCapturePresentation
    let onClose: () -> Void
    @State private var presented = true
    var body: some View {
      Text("Synthetic capture acceptance")
        .frame(width: 760, height: 850)
        .sheet(isPresented: $presented, onDismiss: onClose) { PageCaptureView(model: model) }
    }
  }
#endif
