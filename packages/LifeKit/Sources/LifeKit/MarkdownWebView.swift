import SwiftUI
import WebKit

@MainActor struct MarkdownWebView {
  static let resourceURL = Bundle.module.url(forResource: "editor", withExtension: "html")
  let session: MarkdownEditorSession
  func makeCoordinator() -> Coordinator { Coordinator(session: session) }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let session: MarkdownEditorSession
    private weak var view: WKWebView?
    private var lastSent: MarkdownDocument?

    init(session: MarkdownEditorSession) { self.session = session }

    func makeView() -> WKWebView {
      session.ready = false
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.userContentController.add(self, name: "editor")
      let view = WKWebView(frame: .zero, configuration: config)
      self.view = view
      view.navigationDelegate = self
      session.snapshot = { [weak self] in
        guard let self else {
          throw WorkspaceError(message: "The editor is unavailable.", violations: [])
        }
        return try await self.snapshot(lock: true)
      }
      if let url = MarkdownWebView.resourceURL,
        let html = try? String(contentsOf: url, encoding: .utf8)
      {
        view.loadHTMLString(html, baseURL: nil)
      } else {
        session.fail("The editor could not load. Your Markdown source is available below.")
      }
      return view
    }

    func render() {
      guard session.ready, let view, lastSent != session.document else { return }
      let document = session.document
      guard let data = try? JSONEncoder().encode(document),
        let payload = try? JSONSerialization.jsonObject(with: data)
      else { return }
      lastSent = document
      view.callAsyncJavaScript(
        "window.lifeEditor.setDocument(document)", arguments: ["document": payload], in: nil,
        in: .page
      ) { [weak self] result in
        guard let self, self.session.document.id == document.id else { return }
        if case .failure = result {
          self.session.fail(
            "The editor is unavailable. Your last received source is available below.")
        }
      }
    }

    func snapshot(lock: Bool = false) async throws -> MarkdownDocument {
      guard session.ready, let view else {
        throw WorkspaceError(
          message: "The editor is unavailable. Your draft has been kept.", violations: [])
      }
      let json: String = try await withCheckedThrowingContinuation { continuation in
        view.callAsyncJavaScript(
          """
          const document = window.lifeEditor.getDocument();
          if (lock) window.lifeEditor.setDocument({...document, readOnly: true});
          return JSON.stringify(document);
          """, arguments: ["lock": lock], in: nil, in: .page
        ) { result in
          switch result {
          case .success(let value):
            if let json = value as? String {
              continuation.resume(returning: json)
            } else {
              continuation.resume(
                throwing: WorkspaceError(
                  message: "The editor returned an invalid document.", violations: []))
            }
          case .failure(let error): continuation.resume(throwing: error)
          }
        }
      }
      return try JSONDecoder().decode(MarkdownDocument.self, from: Data(json.utf8))
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
      if body["type"] as? String == "ready" {
        session.markReady()
        lastSent = nil
        render()
      } else if session.receive(body) {
        // Do not echo a keystroke back through setDocument and reset the selection.
        if lastSent?.id == session.document.id { lastSent = session.document }
      }
    }

    static func allowsNavigation(_ url: URL?) -> Bool { url?.absoluteString == "about:blank" }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(Self.allowsNavigation(navigationAction.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      session.fail("The editor is unavailable. Your last received source is available below.")
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      session.fail("The editor could not load. Your Markdown source is available below.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      session.fail("The editor stopped. Your last received source is available below.")
    }
    func stop(_ view: WKWebView) {
      view.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
      view.navigationDelegate = nil
      view.stopLoading()
      session.invalidate()
    }
  }
}

#if os(macOS)
  extension MarkdownWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.render() }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
      coordinator.stop(view)
    }
  }
#else
  extension MarkdownWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.render() }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
      coordinator.stop(view)
    }
  }
#endif
