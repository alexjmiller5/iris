import SwiftUI
import WebKit

#if os(macOS)
  typealias PlatformSVGView = NSViewRepresentable
#else
  typealias PlatformSVGView = UIViewRepresentable
#endif

/// SVG is only an image subresource: never an executable SVG document.
struct NativeSVGPreview: PlatformSVGView {
  let data: Data

  nonisolated static func document(_ data: Data) -> String {
    """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img{width:100%;height:100%;object-fit:contain}</style></head><body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
    """
  }

  static func configuration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    return config
  }

  func makeCoordinator() -> Coordinator { Coordinator() }
  private func make(_ coordinator: Coordinator) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: Self.configuration())
    view.navigationDelegate = coordinator
    return view
  }
  private func update(_ view: WKWebView, _ coordinator: Coordinator) {
    guard coordinator.data != data else { return }
    coordinator.data = data
    view.loadHTMLString(Self.document(data), baseURL: nil)
  }
  #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
      view.stopLoading()
      view.navigationDelegate = nil
    }
  #else
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
      view.stopLoading()
      view.navigationDelegate = nil
    }
  #endif

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
    var data: Data?
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(
        action.navigationType == .other && action.targetFrame?.isMainFrame == true
          && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
  }
}
