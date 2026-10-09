import SwiftUI
import WebKit

/// The same offline graph component used by the web app. No SQL bridge or token is exposed.
#if os(macOS)
  typealias PlatformGraphView = NSViewRepresentable
#else
  typealias PlatformGraphView = UIViewRepresentable
#endif

struct SchemaGraphView: PlatformGraphView {
  static let resourceURL = Bundle.module.url(forResource: "graph", withExtension: "html")
  let catalog: WorkspaceCatalog
  let groups: [String: String]
  let openTable: (String) -> Void
  let saveGroups: ([String: String]) -> Void

  #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { updateWebView(view, context: context) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
      dismantleWebView(view, coordinator: coordinator)
    }
  #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { updateWebView(view, context: context) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
      dismantleWebView(view, coordinator: coordinator)
    }
  #endif

  func makeCoordinator() -> Coordinator { Coordinator() }
  private func makeWebView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "irisGraph")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    if let url = Self.resourceURL,
      let html = try? String(contentsOf: url, encoding: .utf8)
    {
      view.loadHTMLString(html, baseURL: nil)
    }
    return view
  }
  private func updateWebView(_ view: WKWebView, context: Context) {
    context.coordinator.tableIDs = Set(catalog.tables.compactMap { $0["id"]?.text })
    context.coordinator.openTable = openTable
    context.coordinator.saveGroups = saveGroups
    context.coordinator.payload = .object([
      "tables": .array(catalog.tables.map(JSONValue.object)),
      "properties": .array(catalog.properties.map(JSONValue.object)),
      "groups": .object(groups.mapValues(JSONValue.string)),
    ])
    if context.coordinator.ready { context.coordinator.render(in: view) }
  }
  private static func dismantleWebView(_ view: WKWebView, coordinator: Coordinator) {
    view.configuration.userContentController.removeScriptMessageHandler(forName: "irisGraph")
    view.navigationDelegate = nil
    view.stopLoading()
  }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var ready = false
    var tableIDs: Set<String> = []
    var payload: JSONValue = .null
    var openTable: (String) -> Void = { _ in }
    var saveGroups: ([String: String]) -> Void = { _ in }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      ready = true
      render(in: webView)
    }
    func render(in view: WKWebView) {
      guard let data = try? JSONEncoder().encode(payload),
        let value = try? JSONSerialization.jsonObject(with: data)
      else { return }
      view.callAsyncJavaScript(
        "window.IrisGraph.render(payload)", arguments: ["payload": value], in: nil, in: .page,
        completionHandler: nil)
    }
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else {
        return
      }
      if body["type"] as? String == "openTable", let table = body["table"] as? String,
        tableIDs.contains(table)
      {
        openTable(table)
      }
      if body["type"] as? String == "groups", let groups = body["groups"] as? [String: String] {
        saveGroups(groups)
      }
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
  }
}
