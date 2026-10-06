import Foundation
import Network
import Testing
import WebKit

@testable import LifeKit

#if os(macOS)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CAPTURE_HTML"] == "1"))
@MainActor
struct ArchivedHTMLViewTests {
  @Test func nativeLinkPreviewsAreDisabledBeforeLoadingAnArchive() async throws {
    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    // Configuration regression only. Real long-press/force-click acceptance is
    // separate: a DOM click does not exercise native preview presentation.
    #expect(!renderer.webView.allowsLinkPreview)
  }

  @Test(arguments: ["", "<meta charset=\"windows-1252\">"])
  func utf8TextSurvivesConflictingArchiveEncodingMetadata(meta: String) async throws {
    let text = "Café 日本語 🧭 e\u{301}"
    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    let probe = ArchiveNavigationProbe(forwarding: renderer.webView.navigationDelegate)
    renderer.webView.navigationDelegate = probe
    let file = try await verifiedHTML(meta + "<p id=\"unicode\">" + text + "</p>")
    defer { file.dispose() }
    try await renderer.load(file)
    let child = try #require(probe.child)
    let actual = try await renderer.webView.callAsyncJavaScript(
      "return document.getElementById('unicode').textContent", arguments: [:], in: child,
      contentWorld: .defaultClient) as? String
    #expect(actual.map { Array($0.utf8) } == Array(text.utf8))
  }

  @Test func childScriptsAndNetworkHaveRealControlsThenStayInert() async throws {
    let sink = try ArchiveNetworkSink()
    defer { sink.close() }
    let origin = try await sink.start()
    let html = """
      <p id="readable">Retained fixture</p>
      <script>document.documentElement.dataset.executed='yes';fetch('\(origin)/script')</script>
      <img src="\(origin)/image" onerror="document.documentElement.dataset.eventRan='yes'">
      <style>@import url('\(origin)/style');</style>
      <meta http-equiv="Content-Security-Policy" content="default-src * 'unsafe-inline'">
      """
    let control = ArchiveProbeView()
    defer { control.close() }
    try await control.load(html)
    #expect(try await control.read("return document.documentElement.dataset.executed") as? String == "yes")
    try #require(await sink.waitFor("/script"))
    try #require(await sink.waitFor("/image"))
    try #require(await sink.waitFor("/style"))
    control.close()
    sink.reset()

    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    let probe = ArchiveNavigationProbe(forwarding: renderer.webView.navigationDelegate)
    renderer.webView.navigationDelegate = probe
    let file = try await verifiedHTML(html)
    defer { file.dispose() }
    try await renderer.load(file)
    let child = try #require(probe.child)
    #expect(try await renderer.webView.callAsyncJavaScript(
      "return document.documentElement.dataset.executed || null", arguments: [:], in: child,
      contentWorld: .defaultClient) is NSNull)
    #expect(try await renderer.webView.callAsyncJavaScript(
      "return document.getElementById('readable').textContent", arguments: [:], in: child,
      contentWorld: .defaultClient) as? String == "Retained fixture")
    #expect(try await renderer.webView.evaluateJavaScript(
      "document.querySelectorAll('iframe').length === 1 && document.querySelector('iframe').contentDocument === null") as? Bool == true)
    // Finite observation window, not a claim about every possible future packet.
    try await Task.sleep(for: .milliseconds(250))
    #expect(sink.paths.isEmpty, Comment(rawValue: "Unexpected page requests: \(sink.paths)"))
    #expect(!renderer.webView.configuration.websiteDataStore.isPersistent)
    #expect(!renderer.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    #expect(renderer.webView.configuration.userContentController.userScripts.isEmpty)
  }

  @Test func realFormAndLinkRoutingAreBlockedAfterPermissiveControls() async throws {
    for form in [true, false] {
      let sink = try ArchiveNetworkSink()
      defer { sink.close() }
      let origin = try await sink.start()
      let html = """
        <form id="submit" action="\(origin)/form" method="post"><input name="fixture" value="synthetic"></form>
        <a id="navigate" href="\(origin)/navigate">Navigate</a>
        """
      let action = form ? "document.getElementById('submit').requestSubmit();" : "document.getElementById('navigate').click();"
      let destination = form ? "/form" : "/navigate"
      let control = ArchiveProbeView()
      defer { control.close() }
      try await control.load(html)
      _ = try await control.read(action)
      try #require(await sink.waitFor(destination), "Permissive control must actually reach the sink")
      control.close()
      sink.reset()

      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let probe = ArchiveNavigationProbe(forwarding: renderer.webView.navigationDelegate)
      renderer.webView.navigationDelegate = probe
      let file = try await verifiedHTML(html)
      defer { file.dispose() }
      try await renderer.load(file)
      let child = try #require(probe.child)
      // Privileged test injection drives the real WK submission/link algorithm. It is
      // not a production script/handler and does not claim trusted human-gesture proof.
      _ = try await renderer.webView.callAsyncJavaScript(action, arguments: [:], in: child, contentWorld: .defaultClient)
      try await Task.sleep(for: .milliseconds(250))
      #expect(sink.paths.isEmpty)
      #expect(renderer.webView.url?.absoluteString == "about:blank")
      #expect(!probe.allowedExternalNavigation)
    }
  }

  @Test func hostileQuotesCannotEscapeTheFrame() async throws {
    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    let file = try await verifiedHTML("\"><div id='escaped'>outside</div><p>&amp; preserved</p></iframe><script>document.body.dataset.escape='yes'</script>")
    defer { file.dispose() }
    try await renderer.load(file)
    #expect(try await renderer.webView.evaluateJavaScript(
      "document.querySelectorAll('iframe').length === 1 && !document.getElementById('escaped') && !document.body.dataset.escape") as? Bool == true)
  }

  @Test func closedAndAlreadyUsedRenderersCannotLoadAnotherAttempt() async throws {
    let file = try await verifiedHTML("<p>Retained fixture</p>")
    defer { file.dispose() }
    let closed = try await ArchivedHTMLRenderer.make()
    closed.close()
    await #expect(throws: CancellationError.self) { try await closed.load(file) }
    let used = try await ArchivedHTMLRenderer.make()
    defer { used.close() }
    try await used.load(file)
    await #expect(throws: CancellationError.self) { try await used.load(file) }
  }

  @Test(arguments: ["frame", "nested-data-image", "meta-refresh"])
  func nestedContentCannotLoadOutsideTheArchive(kind: String) async throws {
    let sink = try ArchiveNetworkSink()
    defer { sink.close() }
    let origin = try await sink.start()
    let destination = "/" + kind
    let html: String
    switch kind {
    case "frame": html = "<iframe src=\"\(origin)\(destination)\"></iframe>"
    case "nested-data-image":
      let nested = Data("<img src=\"\(origin)\(destination)\">".utf8).base64EncodedString()
      html = "<iframe src=\"data:text/html;charset=utf-8;base64,\(nested)\"></iframe>"
    default: html = "<meta http-equiv=\"refresh\" content=\"0;url=\(origin)\(destination)\">"
    }
    try await assertBlockedRequest(html: html, action: nil, destination: destination, sink: sink)
  }

  @Test(arguments: ["form-get", "link-top", "link-blank", "download", "popup"])
  func additionalDOMRoutesCannotLeaveTheArchive(kind: String) async throws {
    let sink = try ArchiveNetworkSink()
    defer { sink.close() }
    let origin = try await sink.start()
    let destination = "/" + kind
    let html: String
    let action: String
    switch kind {
    case "form-get":
      html = "<form id=\"route\" action=\"\(origin)\(destination)\" method=\"get\"><input name=\"fixture\" value=\"synthetic\"></form>"
      action = "document.getElementById('route').requestSubmit();"
    case "popup":
      html = "<p>Popup fixture</p>"
      action = "window.open('\(origin)\(destination)', '_blank');"
    default:
      let attribute = kind == "download" ? "download=\"fixture.txt\"" :
        "target=\"\(kind == "link-top" ? "_top" : "_blank")\""
      html = "<a id=\"route\" href=\"\(origin)\(destination)\" \(attribute)>Route</a>"
      action = "document.getElementById('route').click();"
    }
    // These cover DOM routing and attempted resource acquisition. In particular,
    // a download attribute does not prove native download UI was exercised.
    let expectedTarget = kind == "form-get" ? "/form-get?fixture=synthetic" : destination
    try await assertBlockedRequest(html: html, action: action, destination: expectedTarget, sink: sink)
  }

  private func assertBlockedRequest(
    html: String, action: String?, destination: String, sink: ArchiveNetworkSink
  ) async throws {
    let control = ArchiveProbeView()
    defer { control.close() }
    try await control.load(html)
    if let action { _ = try await control.read(action) }
    try #require(await sink.waitFor(destination), "Control must reach the synthetic destination")
    control.close()
    sink.reset()

    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    let probe = ArchiveNavigationProbe(forwarding: renderer.webView.navigationDelegate)
    renderer.webView.navigationDelegate = probe
    let file = try await verifiedHTML(html)
    defer { file.dispose() }
    try await renderer.load(file)
    if let action {
      let child = try #require(probe.child)
      _ = try await renderer.webView.callAsyncJavaScript(
        action, arguments: [:], in: child, contentWorld: .defaultClient)
    }
    try await Task.sleep(for: .milliseconds(250))
    #expect(sink.paths.isEmpty, Comment(rawValue: "Unexpected requests: \(sink.paths)"))
    #expect(!probe.allowedExternalNavigation)
    #expect(renderer.webView.url?.absoluteString == "about:blank")
  }

  @Test(arguments: ["life-archive-test://unregistered.invalid/", "mailto:fixture@example.test"])
  func externalSchemeDOMAttemptsAreNeverAdmitted(destination: String) async throws {
    let html = "<a id=\"external\" href=\"\(destination)\">External fixture</a>"
    let action = "document.getElementById('external').click();"
    let control = ArchiveProbeView()
    defer { control.close() }
    try await control.load(html)
    // The permissive child proves the DOM action reaches native admission, but
    // this terminal test interceptor cancels it. Never launch Mail or another app.
    let interception = ArchiveNavigationProbe(forwarding: nil)
    control.view.navigationDelegate = interception
    _ = try await control.read(action)
    try #require(await interception.waitForAttempt(destination))
    control.close()

    let renderer = try await ArchivedHTMLRenderer.make()
    defer { renderer.close() }
    let probe = ArchiveNavigationProbe(forwarding: renderer.webView.navigationDelegate)
    renderer.webView.navigationDelegate = probe
    let file = try await verifiedHTML(html)
    defer { file.dispose() }
    try await renderer.load(file)
    let child = try #require(probe.child)
    _ = try await renderer.webView.callAsyncJavaScript(
      action, arguments: [:], in: child, contentWorld: .defaultClient)
    try await Task.sleep(for: .milliseconds(250))
    #expect(!probe.allowedURLs.contains(destination))
    #expect(renderer.webView.url?.absoluteString == "about:blank")
    // No assertion here claims actual OS handoff or trusted gesture coverage.
  }

  @Test func cancellationFinishesWhileRealNavigationAdmissionIsHeld() async throws {
    let renderer = try await ArchivedHTMLRenderer.make()
    let hold = ArchiveAdmissionHold()
    renderer.webView.navigationDelegate = hold
    let file = try await verifiedHTML("<p>Cancellation fixture</p>")
    defer { file.dispose(); hold.release(); renderer.close() }
    let result = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let load = Task { @MainActor in
      do { try await renderer.load(file); result.continuation.yield(false) }
      catch is CancellationError { result.continuation.yield(true) }
      catch { result.continuation.yield(false) }
      result.continuation.finish()
    }
    defer { load.cancel() }
    try #require(await hold.waitUntilHeld(), "Real WK admission must be held before cancellation")
    load.cancel()
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      result.continuation.yield(false)
      result.continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = result.stream.makeAsyncIterator()
    // Do not await a possibly stuck load during cleanup. The deferred release
    // disarms WK admission even when this bounded requirement fails.
    try #require(await iterator.next() == true, "Cancellation must finish before releasing admission")
    hold.release()
    await #expect(throws: CancellationError.self) { try await renderer.load(file) }
  }

  private func verifiedHTML(_ html: String) async throws -> RetainedFile {
    let bytes = Data(html.utf8)
    let attempt = try captureWithBytes(bytes)
    return try await attempt.loadArtifact(.html, maximumBytes: PageCapture.previewLimit) { _, _ in
      try RetainedFile(data: bytes, contentType: "text/html", name: "page.html")
    }
  }
}

/// Permissive controls exist only here; no permissive option on the production renderer.
@MainActor private final class ArchiveProbeView: NSObject, WKNavigationDelegate, WKUIDelegate {
  let view: WKWebView
  private var completion: CheckedContinuation<Void, Error>?
  private var child: WKFrameInfo?
  private var popups: [WKWebView] = []
  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
    super.init()
    view.navigationDelegate = self
    view.uiDelegate = self
  }
  func load(_ html: String) async throws {
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      self.finish(.failure(ArchiveProbeError.timeout))
    }
    defer { watchdog.cancel() }
    try await withCheckedThrowingContinuation { continuation in
      completion = continuation
      let encoded = Data(html.utf8).base64EncodedString()
      view.loadHTMLString("<iframe src='data:text/html;base64," + encoded + "'></iframe>", baseURL: nil)
    }
  }
  func read(_ script: String) async throws -> Any? {
    let child = try #require(child)
    return try await view.callAsyncJavaScript(script, arguments: [:], in: child, contentWorld: .defaultClient)
  }
  private func finish(_ result: Result<Void, Error>) {
    let pending = completion
    completion = nil
    pending?.resume(with: result)
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    if let frame = action.targetFrame, !frame.isMainFrame { child = frame }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let popup = WKWebView(frame: .zero, configuration: configuration)
    popups.append(popup)
    return popup
  }
  func close() {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    popups.forEach { $0.stopLoading() }
    popups.removeAll()
    finish(.failure(CancellationError()))
  }
}

@MainActor private final class ArchiveNavigationProbe: NSObject, WKNavigationDelegate {
  let forwarding: (any WKNavigationDelegate)?
  var child: WKFrameInfo?
  var allowedExternalNavigation = false
  // Proposed renderer decisions, before the test's terminal safety override.
  var allowedURLs: [String] = []
  private let attempts = AsyncStream<String>.makeStream()
  init(forwarding: (any WKNavigationDelegate)?) { self.forwarding = forwarding }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    if let frame = action.targetFrame, !frame.isMainFrame { child = frame }
    if let url = action.request.url?.absoluteString { attempts.continuation.yield(url) }
    guard let forwarding else { decisionHandler(.cancel); return }
    forwarding.webView?(webView, decidePolicyFor: action, decisionHandler: { policy in
      if policy == .allow, let url = action.request.url?.absoluteString { self.allowedURLs.append(url) }
      if policy == .allow, ["http", "https"].contains(action.request.url?.scheme ?? "") {
        self.allowedExternalNavigation = true
      }
      // An allow mutant must remain observable without launching another app.
      // Only archive bootstrap and synthetic HTTP(S) routes may reach WebKit.
      let scheme = action.request.url?.scheme?.lowercased() ?? ""
      let externalScheme = !["about", "data", "http", "https"].contains(scheme)
      decisionHandler(externalScheme ? .cancel : policy)
    })
  }
  func waitForAttempt(_ url: String) async -> Bool {
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      attempts.continuation.finish()
    }
    defer { watchdog.cancel() }
    for await attempted in attempts.stream where attempted == url { return true }
    return false
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { forwarding?.webView?(webView, didFinish: navigation) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { forwarding?.webView?(webView, didFail: navigation, withError: error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { forwarding?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
}

/// Holds an actual WK admission callback, not a fabricated renderer completion.
@MainActor private final class ArchiveAdmissionHold: NSObject, WKNavigationDelegate {
  private let arrived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  private var pending: (@MainActor (WKNavigationActionPolicy) -> Void)?
  private var disarmed = false
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    guard !disarmed, pending == nil, action.targetFrame?.isMainFrame == true else {
      decisionHandler(.cancel)
      return
    }
    pending = decisionHandler
    arrived.continuation.yield(())
    arrived.continuation.finish()
  }
  func waitUntilHeld() async -> Bool {
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      release()
    }
    defer { watchdog.cancel() }
    var iterator = arrived.stream.makeAsyncIterator()
    return await iterator.next() != nil
  }
  func release() {
    // Disarm before invoking the callback: teardown and its reentrant or late
    // navigation callbacks must never acquire another hold.
    disarmed = true
    let callback = pending
    pending = nil
    callback?(.cancel)
    arrived.continuation.finish()
  }
}

private enum ArchiveProbeError: Error { case timeout, listener }
private final class ArchiveNetworkSink: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "archive-test-network")
  private let lock = NSLock()
  private var recorded: [String] = []
  private var connections: [NWConnection] = []
  private let events = AsyncStream<String>.makeStream()
  var paths: [String] { lock.withLock { recorded } }
  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }
  func start() async throws -> String {
    let ready = AsyncStream<UInt16>.makeStream(bufferingPolicy: .bufferingNewest(1))
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready: if let port = self?.listener.port { ready.continuation.yield(port.rawValue); ready.continuation.finish() }
      case .failed, .cancelled: ready.continuation.finish()
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.lock.withLock { self.connections.append(connection) }
      connection.start(queue: self.queue)
      self.receive(connection, prefix: Data())
    }
    listener.start(queue: queue)
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      ready.continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = ready.stream.makeAsyncIterator()
    guard let port = await iterator.next() else { throw ArchiveProbeError.listener }
    return "http://127.0.0.1:\(port)"
  }
  private func receive(_ connection: NWConnection, prefix: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
      guard let self else { connection.cancel(); return }
      var bytes = prefix
      bytes.append(data ?? Data())
      if let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") {
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "invalid"
        self.lock.withLock { self.recorded.append(path) }
        self.events.continuation.yield(path)
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
      } else if !done, error == nil, bytes.count < 32768 {
        self.receive(connection, prefix: bytes)
      } else { connection.cancel() }
    }
  }
  func waitFor(_ path: String) async -> Bool {
    if paths.contains(path) { return true }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      events.continuation.finish()
    }
    defer { watchdog.cancel() }
    for await received in events.stream where received == path { return true }
    return false
  }
  func reset() { lock.withLock { recorded = [] } }
  func close() {
    listener.cancel()
    let active = lock.withLock { connections }
    active.forEach { $0.cancel() }
    events.continuation.finish()
  }
}
#endif
