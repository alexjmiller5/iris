#if canImport(WebKit)
  import Foundation
  import Testing
  import WebKit
  @testable import LifeKit

  @MainActor
  struct SchemaGraphTests {
    @Test func bundledGraphRendersAndNavigatesWithoutNetwork() async throws {
      let coordinator = SchemaGraphView.Coordinator()
      coordinator.tableIDs = ["widgets", "categories"]
      coordinator.payload = .object([
        "tables": .array([
          .object(["id": .string("widgets"), "purpose": .string("Synthetic table")]),
          .object(["id": .string("categories")]),
        ]),
        "properties": .array([
          .object([
            "tbl": .string("widgets"), "col": .string("category"),
            "type": .string("ref"), "ref_table": .string("categories"),
          ])
        ]),
        "groups": .object(["widgets": .string("Inventory")]),
      ])
      var opened: String?
      var savedGroups: [String: String]?
      coordinator.saveGroups = { savedGroups = $0 }
      coordinator.openTable = { opened = $0 }
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.userContentController.add(coordinator, name: "lifeGraph")
      let view = WKWebView(frame: .zero, configuration: config)
      view.navigationDelegate = coordinator
      defer {
        config.userContentController.removeScriptMessageHandler(forName: "lifeGraph")
        view.stopLoading()
      }
      let file = try #require(SchemaGraphView.resourceURL)
      view.loadHTMLString(try String(contentsOf: file, encoding: .utf8), baseURL: nil)
      for _ in 0..<200 where !coordinator.ready { try await Task.sleep(for: .milliseconds(20)) }
      #expect(coordinator.ready)
      let rendered = try await script(
        view, "JSON.stringify(document.body.textContent.includes('widgets'))")
      #expect(rendered == "true")
      _ = try await script(
        view,
        "[...document.querySelectorAll('button')].find(b => b.textContent.includes('widgets')).click(); 'clicked'"
      )
      for _ in 0..<50 where opened == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(opened == "widgets")
      let relationships = try await script(
        view, "String(document.querySelectorAll('.relationship').length)")
      #expect(relationships == "1")
      _ = try await script(
        view, "document.querySelector('.relationships button:last-of-type').click(); 'clicked'")
      for _ in 0..<50 where opened != "categories" { try await Task.sleep(for: .milliseconds(10)) }
      #expect(opened == "categories")
      _ = try await script(
        view,
        "const i = document.querySelector('[aria-label=\"Group for widgets\"]'); i.value='Supplies'; i.dispatchEvent(new Event('change', {bubbles:true})); 'changed'"
      )
      for _ in 0..<50 where savedGroups == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(savedGroups?["widgets"] == "Supplies")
      _ = try await script(
        view,
        "window.webkit.messageHandlers.lifeGraph.postMessage({type:'openTable',table:'not-in-catalog'}); 'sent'"
      )
      try await Task.sleep(for: .milliseconds(50))
      #expect(opened == "categories")
    }
    private func script(_ view: WKWebView, _ script: String) async throws -> String {
      try await withCheckedThrowingContinuation { continuation in
        view.evaluateJavaScript(script) { result, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: String(describing: result ?? ""))
          }
        }
      }
    }
  }
#endif
