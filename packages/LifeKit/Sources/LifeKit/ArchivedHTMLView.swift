import Foundation
import SwiftUI
import WebKit

/// Isolated archive renderer. The host must supply an integrity-verified artifact
/// from PageCapture.loadArtifact, never an arbitrary file or authenticated URL.
@MainActor
final class ArchivedHTMLRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  private var completion: CheckedContinuation<Void, Error>?
  private var navigation: WKNavigation?
  private var used = false
  private var closed = false
  private var mainBootstrap = false
  private var childBootstrap: String?

  private override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.userContentController = WKUserContentController()
    webView = ArchivedWebView(frame: .zero, configuration: configuration)
    // Native preview loading is separate from navigation-delegate admission.
    webView.allowsLinkPreview = false
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  static func make() async throws -> ArchivedHTMLRenderer {
    let rules =
      "["
      + ["^https?:", "^wss?:", "^ftp:", "^file:"].map {
        #"{"trigger":{"url-filter":""# + $0 + #""},"action":{"type":"block"}}"#
      }.joined(separator: ",") + "]"
    let rule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "life-archive-no-network-v1", encodedContentRuleList: rules
      ) { rule, error in
        if let rule {
          continuation.resume(returning: rule)
        } else {
          continuation.resume(throwing: error ?? Failure.unavailable)
        }
      }
    }
    try Task.checkCancellation()
    let renderer = ArchivedHTMLRenderer()
    renderer.webView.configuration.userContentController.add(rule)
    return renderer
  }

  func load(_ file: RetainedFile) async throws {
    try Task.checkCancellation()
    guard !used, !closed else { throw CancellationError() }
    used = true
    guard file.contentType == "text/html" else { throw Failure.unavailable }
    let html = try await Task.detached(priority: .utility) {
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }
      let bytes = try handle.read(upToCount: PageCapture.previewLimit + 1) ?? Data()
      guard bytes.count <= PageCapture.previewLimit,
        let html = String(data: bytes, encoding: .utf8)
      else { throw Failure.unavailable }
      return html
    }.value
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    // With content JavaScript disabled WebKit strips srcdoc attributes. Use an
    // in-memory data document, never a file directory or a network base URL.
    let policy =
      "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
    let child =
      "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">"
      + html
    let childURL = "data:text/html;charset=utf-8;base64," + Data(child.utf8).base64EncodedString()
    let wrapper = """
      <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; frame-src data:; form-action 'none'; base-uri 'none'">
      <style>html,body,iframe{margin:0;border:0;width:100%;height:100%}</style>
      <iframe sandbox="" title="Archived page" src="\(childURL)"></iframe>
      """
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      self.closePending(error: Failure.timeout)
    }
    defer { watchdog.cancel() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        completion = continuation
        mainBootstrap = true
        childBootstrap = childURL
        navigation = webView.loadHTMLString(wrapper, baseURL: nil)
      }
    } onCancel: {
      Task { @MainActor in self.close() }
    }
    try Task.checkCancellation()
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let url = action.request.url?.absoluteString
    if mainBootstrap, action.targetFrame?.isMainFrame == true, url == "about:blank" {
      mainBootstrap = false
      decisionHandler(.allow)
    } else if let childBootstrap, action.targetFrame?.isMainFrame == false, url == childBootstrap {
      self.childBootstrap = nil
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard navigation === self.navigation else { return }
    finish(.success(()))
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard navigation === self.navigation else { return }
    finish(.failure(error))
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard navigation === self.navigation else { return }
    finish(.failure(error))
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }

  private func finish(_ result: Result<Void, Error>) {
    let pending = completion
    completion = nil
    navigation = nil
    pending?.resume(with: result)
  }

  #if os(iOS)
    func webView(
      _ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? { nil }
  #endif
  private func closePending(error: Error = CancellationError()) {
    mainBootstrap = false
    childBootstrap = nil
    webView.stopLoading()
    finish(.failure(error))
  }
  /// One renderer owns one immutable attempt; dismissal permanently closes it.
  func close() {
    closed = true
    closePending()
  }
  enum Failure: Error { case unavailable, timeout }
}

#if os(macOS)
  struct ArchivedHTMLView: NSViewRepresentable {
    let renderer: ArchivedHTMLRenderer
    func makeNSView(context: Context) -> WKWebView { renderer.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
  }

  private final class ArchivedWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let hit = super.hitTest(point) else { return nil }
      guard let event = NSApp.currentEvent else { return hit }
      // WebKit's internal content view creates menus without calling its parent
      // WKWebView's menu callback. Own contextual gestures before that view sees them.
      if [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(event.type)
        || (event.modifierFlags.contains(.control)
          && [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type))
      {
        return self
      }
      return hit
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
      if !event.modifierFlags.contains(.control) { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
      // Native menu actions can bypass the page's navigation policy.
      // Original-file saving and external navigation belong to explicit host UI.
      menu.removeAllItems()
    }
  }
#else
  struct ArchivedHTMLView: UIViewRepresentable {
    let renderer: ArchivedHTMLRenderer
    func makeUIView(context: Context) -> WKWebView { renderer.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
  }

  private typealias ArchivedWebView = WKWebView
#endif
