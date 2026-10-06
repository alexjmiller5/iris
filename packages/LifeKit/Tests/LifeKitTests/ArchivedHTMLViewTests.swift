import Foundation
import Testing
import WebKit

@testable import LifeKit

// Enable only in the separately allocated renderer/runtime acceptance batch.
// These tests are not included in the focused model test result.
#if PAGE_CAPTURE_HTML_RUNTIME
@MainActor
struct ArchivedHTMLViewTests {
  // This is an actual WK test, not an assertion that source contains CSP words.
  // It requires the separately allocated native runtime window before execution.
  @Test func hostileMarkupCannotEscapeItsOpaqueFrameOrRunPageScripts() async throws {
    let html = Data(#"""
      "><div id="escaped">outside frame</div>
      <script>window.top.document.body.dataset.pageExecuted='yes'</script>
      <svg onload="window.top.document.body.dataset.pageExecuted='yes'"></svg>
      <meta http-equiv="Content-Security-Policy" content="default-src * 'unsafe-inline'">
      <p>Readable retained fixture</p>
      """#.utf8)
    let attempt = try captureWithBytes(html)
    let artifact = try await attempt.loadArtifact(.html, maximumBytes: 4096) { _, _ in
      try RetainedFile(data: html, contentType: "text/html", name: "page.html")
    }
    defer { artifact.dispose() }
    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    try await renderer.load(artifact)
    let evidence = try await renderer.webView.evaluateJavaScript(#"""
      JSON.stringify({
        frames: document.querySelectorAll('iframe').length,
        escaped: !!document.getElementById('escaped'),
        opaque: document.querySelector('iframe').contentDocument === null,
        executed: document.body.dataset.pageExecuted || null
      })
      """#)
    let text = try #require(evidence as? String)
    let result = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(result["frames"] as? Int == 1)
    #expect(result["escaped"] as? Bool == false)
    #expect(result["opaque"] as? Bool == true)
    #expect(result["executed"] is NSNull)
    #expect(!renderer.webView.configuration.websiteDataStore.isPersistent)
    #expect(!renderer.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    #expect(renderer.webView.configuration.userContentController.userScripts.isEmpty)
  }

  // Catches permissive about/file/custom scheme allowlists and repeated bootstrap navigation.
  @Test func onlyTheHostBootstrapMayNavigate() {
    var policy = ArchivedHTMLNavigationPolicy()
    #expect(policy.admit(url: "about:blank", mainFrame: true, userInitiated: false))
    #expect(policy.admit(url: "about:srcdoc", mainFrame: false, userInitiated: false))
    for url in ["https://example.test/", "http://127.0.0.1/", "file:///private/fixture",
                "javascript:alert(1)", "data:text/html,<p>escape</p>", "custom:escape",
                "about:blank", "about:srcdoc"] {
      #expect(!policy.admit(url: url, mainFrame: true, userInitiated: true))
      #expect(!policy.admit(url: url, mainFrame: false, userInitiated: false))
    }
  }

  // Full network-sink and native link/form/download actions belong to the runtime
  // acceptance fixture before activation, not a claim based on the two tests above.
}
#endif
