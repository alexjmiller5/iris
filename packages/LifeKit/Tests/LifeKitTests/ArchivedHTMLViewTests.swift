import Foundation
import Network
import Testing
import WebKit

@testable import LifeKit

#if os(macOS)
  import AppKit

  @Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CAPTURE_HTML"] == "1"))
  @MainActor
  struct ArchivedHTMLViewTests {
    @Test func nativeContextMenuCallbackDoesNotOfferExternalActions() async throws {
      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let menu = NSMenu()
      menu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
      menu.addItem(withTitle: "Download Linked File", action: nil, keyEquivalent: "")
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      renderer.webView.willOpenMenu(menu, with: event)
      #expect(menu.items.isEmpty)
    }

    @Test func cancelledLoadNeverReadsAnArtifact() async throws {
      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let file = try await verifiedHTML("<p>cancelled fixture</p>")
      file.dispose()
      let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await #expect(throws: CancellationError.self) { try await renderer.load(file) }
      }
      await operation.value
      #expect(renderer.webView.url == nil)
    }

    @Test(arguments: [false, true])
    func invalidOrOversizedHTMLNeverStartsNavigation(oversized: Bool) async throws {
      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let bytes =
        oversized ? Data(repeating: 32, count: PageCapture.previewLimit + 1) : Data([0xff])
      let file = try RetainedFile(data: bytes, contentType: "text/html", name: "page.html")
      defer { file.dispose() }
      await #expect(throws: ArchivedHTMLRenderer.Failure.self) { try await renderer.load(file) }
      #expect(renderer.webView.url == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CAPTURE_GESTURES"] == "1"))
    func nativeContextAndClickActionsRemainInsideTheArchive() async throws {
      try #require(
        Bundle.main.bundleURL.pathExtension == "app", "Use the application-hosted test target")
      let sink = try ArchiveNetworkSink()
      defer { sink.close() }
      let origin = try await sink.start()
      let html = """
        <style>a{display:block;margin:12px;font:20px system-ui}</style>
        <a href="\(origin)/native-link">Native capture link</a>
        <a href="\(origin)/native-download" download="fixture.txt">Native capture download</a>
        """
      let control = ArchiveProbeView()
      defer { control.close() }
      try await control.load(html)
      let permissive = ArchiveNativeInteractionProbe(view: control.view, phase: "control")
      defer { permissive.close() }
      try await permissive.run()
      #expect(permissive.contextEvents > 0, "A real native contextual gesture is required")
      #expect(
        permissive.menuTitles.contains { !$0.isEmpty }, "Control must expose a native context menu")
      #expect(permissive.clickEvents > 0, "A native click is required")
      try #require(
        await sink.waitFor("/native-link"), "The permissive click must reach the synthetic sink")
      permissive.close()
      control.close()
      sink.reset()

      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let file = try await verifiedHTML(html)
      defer { file.dispose() }
      try await renderer.load(file)
      let protected = ArchiveNativeInteractionProbe(view: renderer.webView, phase: "protected")
      defer { protected.close() }
      try await protected.run()
      #expect(protected.contextEvents > 0)
      #expect(protected.clickEvents >= 2, "Click both the link and download-attributed link")
      #expect(
        protected.menuTitles.allSatisfy { $0.isEmpty },
        "An archive must not offer native external actions")
      try await Task.sleep(for: .milliseconds(250))
      #expect(sink.paths.isEmpty)
      #expect(renderer.webView.url?.absoluteString == "about:blank")
    }

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
      let actual =
        try await renderer.webView.callAsyncJavaScript(
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
      #expect(
        try await control.read("return document.documentElement.dataset.executed") as? String
          == "yes")
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
      #expect(
        try await renderer.webView.callAsyncJavaScript(
          "return document.documentElement.dataset.executed || null", arguments: [:], in: child,
          contentWorld: .defaultClient) is NSNull)
      #expect(
        try await renderer.webView.callAsyncJavaScript(
          "return document.getElementById('readable').textContent", arguments: [:], in: child,
          contentWorld: .defaultClient) as? String == "Retained fixture")
      #expect(
        try await renderer.webView.evaluateJavaScript(
          "document.querySelectorAll('iframe').length === 1 && document.querySelector('iframe').contentDocument === null"
        ) as? Bool == true)
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
        let action =
          form
          ? "document.getElementById('submit').requestSubmit();"
          : "document.getElementById('navigate').click();"
        let destination = form ? "/form" : "/navigate"
        let control = ArchiveProbeView()
        defer { control.close() }
        try await control.load(html)
        _ = try await control.read(action)
        try #require(
          await sink.waitFor(destination), "Permissive control must actually reach the sink")
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
        _ = try await renderer.webView.callAsyncJavaScript(
          action, arguments: [:], in: child, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(250))
        #expect(sink.paths.isEmpty)
        #expect(renderer.webView.url?.absoluteString == "about:blank")
        #expect(!probe.allowedExternalNavigation)
      }
    }

    @Test func hostileQuotesCannotEscapeTheFrame() async throws {
      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let file = try await verifiedHTML(
        "\"><div id='escaped'>outside</div><p>&amp; preserved</p></iframe><script>document.body.dataset.escape='yes'</script>"
      )
      defer { file.dispose() }
      try await renderer.load(file)
      #expect(
        try await renderer.webView.evaluateJavaScript(
          "document.querySelectorAll('iframe').length === 1 && !document.getElementById('escaped') && !document.body.dataset.escape"
        ) as? Bool == true)
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
        html =
          "<form id=\"route\" action=\"\(origin)\(destination)\" method=\"get\"><input name=\"fixture\" value=\"synthetic\"></form>"
        action = "document.getElementById('route').requestSubmit();"
      case "popup":
        html = "<p>Popup fixture</p>"
        action = "window.open('\(origin)\(destination)', '_blank');"
      default:
        let attribute =
          kind == "download"
          ? "download=\"fixture.txt\"" : "target=\"\(kind == "link-top" ? "_top" : "_blank")\""
        html = "<a id=\"route\" href=\"\(origin)\(destination)\" \(attribute)>Route</a>"
        action = "document.getElementById('route').click();"
      }
      // These cover DOM routing and attempted resource acquisition. In particular,
      // a download attribute does not prove native download UI was exercised.
      let expectedTarget = kind == "form-get" ? "/form-get?fixture=synthetic" : destination
      try await assertBlockedRequest(
        html: html, action: action, destination: expectedTarget, sink: sink)
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
      let renderer = try await ArchivedHTMLRenderer.make()
      defer { renderer.close() }
      let control = ArchiveProbeView()
      defer { control.close() }
      try await control.load(html)
      // Exercise the production default-denial branch using a real action from a
      // permissive child. The terminal probe still cancels an allow mutant before
      // WebKit receives it, so this can never launch Mail or another external app.
      let interception = ArchiveNavigationProbe(forwarding: renderer)
      control.view.navigationDelegate = interception
      _ = try await control.read(action)
      try #require(await interception.waitForAttempt(destination))
      #expect(interception.proposedPolicies[destination] == .cancel)
      control.close()

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
      defer {
        file.dispose()
        hold.release()
        renderer.close()
      }
      let result = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let load = Task { @MainActor in
        do {
          try await renderer.load(file)
          result.continuation.yield(false)
        } catch is CancellationError { result.continuation.yield(true) } catch {
          result.continuation.yield(false)
        }
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
      try #require(
        await iterator.next() == true, "Cancellation must finish before releasing admission")
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

  /// Application-hosted native gesture fixture. Its buttons and permissive control
  /// are test-only; no app launch flag or permissive production renderer is added.
  @MainActor private final class ArchiveNativeInteractionProbe: NSObject {
    let window: NSWindow
    private let view: WKWebView
    private var monitor: Any?
    private var trackedMenus: [NSMenu] = []
    private var finished = false
    private(set) var menuTitles: [[String]] = []
    private(set) var clickEvents = 0
    private(set) var contextEvents = 0
    private let phase: String

    init(view: WKWebView, phase: String) {
      self.view = view
      self.phase = phase
      window = NSWindow(
        contentRect: NSRect(x: 120, y: 120, width: 640, height: 520),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Archive gesture " + phase
      super.init()
      let finish = NSButton(title: "Finish " + phase, target: self, action: #selector(finishPhase))
      let dismissMenu = NSButton(
        title: "Dismiss context menu", target: self, action: #selector(dismissMenus))
      let stack = NSStackView(views: [view, NSStackView(views: [dismissMenu, finish])])
      stack.orientation = .vertical
      stack.alignment = .centerX
      view.widthAnchor.constraint(equalToConstant: 640).isActive = true
      view.heightAnchor.constraint(equalToConstant: 480).isActive = true
      window.contentView = stack
      NotificationCenter.default.addObserver(
        self, selector: #selector(menuOpened(_:)), name: NSMenu.didBeginTrackingNotification,
        object: nil)
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        guard let self, event.window === self.window,
          self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil))
        else { return event }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
          self.contextEvents += 1
        } else {
          self.clickEvents += 1
        }
        return event
      }
    }

    func run() async throws {
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      FileHandle.standardError.write(
        Data("CAPTURE_GESTURE_READY=\(phase) WINDOW=\(window.windowNumber)\n".utf8))
      let deadline = ContinuousClock.now.advanced(by: .seconds(90))
      while !finished && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      FileHandle.standardError.write(
        Data(
          "CAPTURE_GESTURE_RESULT=\(phase) clicks=\(clickEvents) contextual=\(contextEvents) menus=\(menuTitles)\n"
            .utf8))
      try #require(finished, "Complete the synthetic native gesture phase")
    }

    @objc private func finishPhase() { finished = true }
    @objc private func dismissMenus() { trackedMenus.forEach { $0.cancelTracking() } }
    @objc private func menuOpened(_ notification: Notification) {
      guard let menu = notification.object as? NSMenu else { return }
      menuTitles.append(menu.items.map(\.title))
      trackedMenus.append(menu)
    }
    func close() {
      NotificationCenter.default.removeObserver(self)
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      trackedMenus.forEach { $0.cancelTracking() }
      trackedMenus.removeAll()
      window.close()
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
        view.loadHTMLString(
          "<iframe src='data:text/html;base64," + encoded + "'></iframe>", baseURL: nil)
      }
    }
    func read(_ script: String) async throws -> Any? {
      let child = try #require(child)
      return try await view.callAsyncJavaScript(
        script, arguments: [:], in: child, contentWorld: .defaultClient)
    }
    private func finish(_ result: Result<Void, Error>) {
      let pending = completion
      completion = nil
      pending?.resume(with: result)
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      if let frame = action.targetFrame, !frame.isMainFrame { child = frame }
      decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      finish(.failure(error))
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { finish(.failure(error)) }
    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
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
    var proposedPolicies: [String: WKNavigationActionPolicy] = [:]
    private let attempts = AsyncStream<String>.makeStream()
    init(forwarding: (any WKNavigationDelegate)?) { self.forwarding = forwarding }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      if let frame = action.targetFrame, !frame.isMainFrame { child = frame }
      if let url = action.request.url?.absoluteString { attempts.continuation.yield(url) }
      guard let forwarding else {
        decisionHandler(.cancel)
        return
      }
      forwarding.webView?(
        webView, decidePolicyFor: action,
        decisionHandler: { policy in
          if let url = action.request.url?.absoluteString { self.proposedPolicies[url] = policy }
          if policy == .allow, let url = action.request.url?.absoluteString {
            self.allowedURLs.append(url)
          }
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      forwarding?.webView?(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      forwarding?.webView?(webView, didFail: navigation, withError: error)
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { forwarding?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
  }

  /// Holds an actual WK admission callback, not a fabricated renderer completion.
  @MainActor private final class ArchiveAdmissionHold: NSObject, WKNavigationDelegate {
    private let arrived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var pending: (@MainActor (WKNavigationActionPolicy) -> Void)?
    private var disarmed = false
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
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
        case .ready:
          if let port = self?.listener.port {
            ready.continuation.yield(port.rawValue)
            ready.continuation.finish()
          }
        case .failed, .cancelled: ready.continuation.finish()
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else {
          connection.cancel()
          return
        }
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
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
        [weak self] data, _, done, error in
        guard let self else {
          connection.cancel()
          return
        }
        var bytes = prefix
        bytes.append(data ?? Data())
        if let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") {
          let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "invalid"
          self.lock.withLock { self.recorded.append(path) }
          self.events.continuation.yield(path)
          let reply = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
              .utf8)
          connection.send(
            content: reply, completion: .contentProcessed { _ in connection.cancel() })
        } else if !done, error == nil, bytes.count < 32768 {
          self.receive(connection, prefix: bytes)
        } else {
          connection.cancel()
        }
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
