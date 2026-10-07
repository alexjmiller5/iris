import Foundation
import WebKit

/// Unmounted archive renderer. The host must supply an integrity-verified artifact
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
    webView = WKWebView(frame: .zero, configuration: configuration)
    // Native preview loading is separate from navigation-delegate admission.
    webView.allowsLinkPreview = false
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  static func make() async throws -> ArchivedHTMLRenderer {
    let rules = "[" + ["^https?:", "^wss?:", "^ftp:", "^file:"].map {
      #"{"trigger":{"url-filter":""# + $0 + #""},"action":{"type":"block"}}"#
    }.joined(separator: ",") + "]"
    let rule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "life-archive-no-network-v1", encodedContentRuleList: rules
      ) { rule, error in
        if let rule { continuation.resume(returning: rule) }
        else { continuation.resume(throwing: error ?? Failure.unavailable) }
      }
    }
    try Task.checkCancellation()
    let renderer = ArchivedHTMLRenderer()
    renderer.webView.configuration.userContentController.add(rule)
    return renderer
  }

  func load(_ file: RetainedFile) async throws {
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
    let policy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
    let child = "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">" + html
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

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url?.absoluteString
    if mainBootstrap, action.targetFrame?.isMainFrame == true, url == "about:blank" {
      mainBootstrap = false
      decisionHandler(.allow)
    } else if let childBootstrap, action.targetFrame?.isMainFrame == false, url == childBootstrap {
      self.childBootstrap = nil
      decisionHandler(.allow)
    } else { decisionHandler(.cancel) }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard navigation === self.navigation else { return }
    finish(.success(()))
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard navigation === self.navigation else { return }
    finish(.failure(error))
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard navigation === self.navigation else { return }
    finish(.failure(error))
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

  private func finish(_ result: Result<Void, Error>) {
    let pending = completion
    completion = nil
    navigation = nil
    pending?.resume(with: result)
  }
  private func closePending(error: Error = CancellationError()) {
    mainBootstrap = false
    childBootstrap = nil
    webView.stopLoading()
    finish(.failure(error))
  }
  /// One renderer owns one immutable attempt; dismissal permanently closes it.
  func close() { closed = true; closePending() }
  enum Failure: Error { case unavailable, timeout }
}
