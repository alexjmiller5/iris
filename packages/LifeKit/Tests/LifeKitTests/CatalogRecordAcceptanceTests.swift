import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

#if os(macOS)
  import AppKit
  import SwiftUI
#endif

/// Uses the real JSC writer and SQLite, not a manufactured validation error.
@Suite(.serialized) @MainActor
struct CatalogRecordAcceptanceTests {
  @Test func rejectedRuleKeepsDraftAndStoredRevisionUntilCorrection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    try Self.seed(runtime)
    try await Self.establishCoverage(workspace, runtime: runtime)
    let writeability = try await workspace.writeability(table: "record_examples")
    try #require(
      writeability.writable, Comment(rawValue: writeability.reason?.message ?? "Not writable"))
    let properties = try await workspace.catalog().properties.filter {
      $0["tbl"] == .string("record_examples")
    }
    let original = try #require(try await workspace.rows(table: "record_examples").first?.record)
    let journal = EditorDraftStore(
      root: directory, workspace: directory.appendingPathComponent("test.sqlite"))
    let editor = RecordEditorModel(
      properties: properties, original: original, table: "record_examples", store: journal
    ) { patch, baseline in
      try await workspace.write(
        table: "record_examples", patch: patch, expectedUpdatedAt: baseline?["updated_at"]?.text)
    }
    let history = try Self.history(runtime)
    let pending = try await workspace.status().pendingUiEdits
    #expect(editor.draft.fields.contains { $0.id == "title" && $0.required })
    #expect(!editor.draft.fields.contains { ["locked", "computed"].contains($0.id) })
    editor.setValue("Blocked", for: "title")
    editor.setValue("Retained second edit", for: "detail")
    // Mutants: bypass the invariant, replace its message, or acknowledge a rejected patch.
    do {
      try await editor.saveAll()
      Issue.record("The real catalog invariant accepted the blocked title")
    } catch let error as WorkspaceError {
      #expect(
        error.violations.contains {
          $0.rule == "catalog-title" && $0.message == "Fixture title is blocked."
        })
    }
    #expect(editor.violations.contains { $0.message == "Fixture title is blocked." })
    #expect(editor.dirty)
    #expect(editor.draft.values["title"] == "Blocked")
    #expect(editor.draft.values["detail"] == "Retained second edit")
    #expect(editor.draft.original == original)
    #expect(try await workspace.rows(table: "record_examples").first?.record == original)
    #expect(try Self.history(runtime) == history)
    #expect(try await workspace.status().pendingUiEdits == pending)
    let retained = try #require(
      try journal.load(table: "record_examples", recordID: "catalog-record"))
    #expect(retained.draft.values["title"] == "Blocked")
    #expect(retained.draft.values["detail"] == "Retained second edit")
    #expect(retained.draft.original == original)
    editor.setValue("Allowed", for: "title")
    try await editor.saveAll()
    let saved = try #require(try await workspace.rows(table: "record_examples").first?.record)
    #expect(saved["title"] == .string("Allowed"))
    #expect(saved["detail"] == .string("Retained second edit"))
    #expect(saved["locked"] == .string("Immutable fixture value"))
    #expect(saved["computed"] == .string("Derived fixture value"))
    #expect(saved["updated_at"] != original["updated_at"])
    #expect(!editor.dirty && editor.violations.isEmpty)
    #expect(try journal.load(table: "record_examples", recordID: "catalog-record") == nil)
    try await workspace.close()
  }

  #if os(macOS)
    // Hosted AppKit/AX actions, not XCUI or installed-app acceptance. This catches a
    // rejected Save dismissing the editor, dropping drafts, or changing stored data.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_HOSTED"] == "1"))
    func hostedCatalogRuleFailureRetainsDraftAndMetadata() async throws {
      // Guard effects independently of test discovery/filtering.
      guard ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_HOSTED"] == "1" else {
        return
      }
      try Task.checkCancellation()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalog-hosted-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let file = directory.appendingPathComponent("catalog-acceptance.sqlite")
      let credentials = MemoryHubCredentials(nil)
      let model = WorkspaceModel(
        localURL: { directory.appendingPathComponent("local.sqlite") },
        makeTransport: { _ in
          throw WorkspaceError(
            message: "Hosted test must not create a live transport", violations: [])
        }, credentialStore: credentials)
      var seedWorkspace: NativeWorkspace?
      var window: NSWindow?
      // Match the bounded, cancellation-independent supervisor used by
      // ReadAdmissionFixture. Timed-out handles remain tracked for diagnosis.
      func cleanup() async {
        let supervisor = Task { @MainActor in
          if let window {
            for sheet in window.sheets {
              window.endSheet(sheet)
              sheet.close()
            }
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
          }
          let (finished, signal) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
          var timedOut = false
          let closing = Task { @MainActor in
            defer {
              signal.yield(())
              signal.finish()
            }
            do {
              await model.close()
              try await seedWorkspace?.close()
              try Task.checkCancellation()
              try #require(model.client == nil, "Owned model failed to close")
              // No suspension between this guard and deletion: a watchdog expiry
              // must retain the directory even if close eventually completes.
              guard !timedOut else { return }
              try FileManager.default.removeItem(at: directory)
            } catch {
              Issue.record(
                "Hosted cleanup incomplete; fixture retained at \(directory.path): \(error)")
            }
          }
          Self.pendingHostedCleanup[directory.path] = closing
          let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            timedOut = true
            signal.finish()
          }
          var iterator = finished.makeAsyncIterator()
          let completed = await iterator.next() != nil
          watchdog.cancel()
          if completed {
            await closing.value  // The completion signal is the task's final defer.
            Self.pendingHostedCleanup.removeValue(forKey: directory.path)
          } else {
            closing.cancel()
            Issue.record(
              "Hosted cleanup exceeded 20 seconds; cleanup incomplete, task tracked and fixture retained at \(directory.path)"
            )
          }
        }
        await supervisor.value
      }
      do {
        let runtime = try LifeCoreRuntime()
        let fixture = try NativeWorkspace(path: file.path, runtime: runtime)
        seedWorkspace = fixture
        try await fixture.createSample()
        try Self.seed(runtime)
        try await Self.establishCoverage(fixture, runtime: runtime)
        // Keep the idle seed handle until bounded teardown; opening the same file
        // uses NativeWorkspace's existing serialized file coordination.
        await model.open(url: file)
        let workspace = try #require(model.client, Comment(rawValue: model.error ?? "No fixture"))
        let original = try #require(
          try await workspace.rows(table: "record_examples").first?.record)
        let originalHistory = try await workspace.rows(table: "history").map(\.record)
        let originalPending = try await workspace.status().pendingUiEdits

        _ = NSApplication.shared
        let owned = NSWindow(
          contentRect: NSRect(x: 100, y: 100, width: 1100, height: 850),
          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        window = owned
        owned.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        owned.makeKeyAndOrderFront(nil)
        let ui = CatalogHostedUI(window: owned)
        do {
          try await ui.press(id: "sidebar-table-record_examples")
        } catch {
          ui.reportFirstLookupFailure(model: model, identifier: "sidebar-table-record_examples")
          throw error
        }
        try await ui.press(id: "grid-open-catalog-record")
        _ = try await ui.element(id: "field-title", role: .textField)
        let context = try #require(model.editingContext)
        try #require(context.table == "record_examples")
        let journal = try #require(context.draftStore)
        _ = try await ui.element(label: "Required")
        try await ui.press(label: "About Title")
        try await ui.expectText("Short fixture title.")
        try ui.escape()
        try await ui.choose(id: "field-state", containing: "Ready for review.")
        try await ui.expectText("Immutable fixture value")
        try await ui.expectText("Derived fixture value")
        #expect(
          !ui.elements.contains {
            $0.accessibilityIdentifier() == "field-locked" && $0.accessibilityRole() == .textField
          })
        #expect(
          !ui.elements.contains {
            $0.accessibilityIdentifier() == "field-computed" && $0.accessibilityRole() == .textField
          })
        try await ui.press(id: "catalog-rules")
        try await ui.expectText("Fixture title is blocked.")
        try await ui.press(label: "Back")
        try await ui.replace(id: "field-title", with: "Blocked")
        try await ui.replace(id: "field-detail", with: "Retained second edit")
        try await ui.press(id: "save-record")
        try await ui.expectText("Fixture title is blocked.")
        _ = try await ui.element(id: "save-record")
        try await ui.expectValue(id: "field-title", "Blocked")
        try await ui.expectValue(id: "field-detail", "Retained second edit")
        #expect(try await workspace.rows(table: "record_examples").first?.record == original)
        #expect(try await workspace.rows(table: "history").map(\.record) == originalHistory)
        #expect(try await workspace.status().pendingUiEdits == originalPending)
        let retained = try #require(
          try journal.load(table: "record_examples", recordID: "catalog-record"))
        #expect(retained.draft.values["title"] == "Blocked")
        #expect(retained.draft.values["detail"] == "Retained second edit")
        #expect(retained.draft.original == original)
        try await ui.replace(id: "field-title", with: "Allowed")
        try await ui.press(id: "save-record")
        try await ui.press(label: "Open Allowed")
        try await ui.expectValue(id: "field-title", "Allowed")
        try await ui.expectValue(id: "field-detail", "Retained second edit")
        let saved = try #require(try await workspace.rows(table: "record_examples").first?.record)
        #expect(saved["title"] == .string("Allowed"))
        #expect(saved["detail"] == .string("Retained second edit"))
        #expect(saved["state"] == .string("Ready"))
        #expect(saved["locked"] == original["locked"] && saved["computed"] == original["computed"])
        #expect(saved["updated_at"] != original["updated_at"])
        #expect(try journal.load(table: "record_examples", recordID: "catalog-record") == nil)
        #expect(credentials.value == nil && credentials.saves == 0 && credentials.removals == 0)
        try await ui.press(label: "Cancel")
      } catch {
        await cleanup()
        throw error
      }
      await cleanup()
    }

    // Only populated while an owned close is running or after a reported timeout.
    // A timeout is never presented as a released resource or a deleted fixture.
    private static var pendingHostedCleanup: [String: Task<Void, Never>] = [:]

    /// Only traverses this test's window, its sheets/children and rendered AX nodes.
    /// A missing/unsupported control fails after five seconds; no model-action fallback.
    @MainActor private struct CatalogHostedUI {
      let window: NSWindow

      var elements: [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
          guard visited.insert(ObjectIdentifier(object)).inserted else { return }
          if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
          if let window = object as? NSWindow, !window.isVisible { return }
          if let element = object as? any NSAccessibilityProtocol {
            if element.isAccessibilityElement(), !element.accessibilityFrame().isEmpty {
              result.append(element)
            }
            for child in element.accessibilityChildren() ?? [] { visit(child as AnyObject) }
          }
          if let view = object as? NSView { for child in view.subviews { visit(child) } }
          if let window = object as? NSWindow {
            if let content = window.contentView { visit(content) }
            for child in window.sheets + (window.childWindows ?? []) { visit(child) }
          }
        }
        visit(window)
        return result
      }

      // Failure-only diagnostics. The action traversal and its filters stay unchanged.
      func reportFirstLookupFailure(model: WorkspaceModel, identifier: String) {
        func short(_ value: String) -> String {
          String(value.replacingOccurrences(of: "\n", with: " ").prefix(160))
        }
        print(
          "CATALOG_HOSTED_DIAGNOSTIC model client=\(model.client != nil) catalog=\(model.catalog != nil) containsRecordExamples=\(model.catalog?.tables.contains { $0["id"] == .string("record_examples") } ?? false) table=\(short(model.table ?? "nil")) loading=\(model.loading) error=\(short(model.error ?? "nil"))"
        )
        print(
          "CATALOG_HOSTED_DIAGNOSTIC window visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(window.frame) contentBounds=\(String(describing: window.contentView?.bounds))"
        )

        // Only descendants of this window, including its own sheets/popovers.
        var windows = [window]
        var windowIDs = Set([ObjectIdentifier(window)])
        var windowIndex = 0
        while windowIndex < windows.count, windows.count < 16 {
          let current = windows[windowIndex]
          windowIndex += 1
          for child in (current.sheets + (current.childWindows ?? [])).prefix(16) {
            if windows.count < 16, windowIDs.insert(ObjectIdentifier(child)).inserted {
              windows.append(child)
            }
          }
        }
        var visited = Set<ObjectIdentifier>()
        var protocolCount = 0
        var elementCount = 0
        var nonemptyCount = 0
        var hiddenCount = 0
        var acceptedCount = 0
        var truncated = false
        var samples: [String] = []
        var matches: [String] = []
        // SwiftUI can expose informal ObjC AX objects without protocol conformance.
        // Inspect string/children getters when present; never invoke an action here.
        func stringGetter(_ object: AnyObject, _ name: String) -> String? {
          guard let object = object as? NSObject else { return nil }
          let selector = NSSelectorFromString(name)
          guard object.responds(to: selector) else { return nil }
          return object.perform(selector)?.takeUnretainedValue() as? String
        }
        func childrenGetter(_ object: AnyObject) -> [Any] {
          guard let object = object as? NSObject else { return [] }
          let selector = NSSelectorFromString("accessibilityChildren")
          guard object.responds(to: selector) else { return [] }
          return object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
        }
        func visit(_ object: AnyObject, hiddenAncestor: Bool, depth: Int) {
          if let owner = (object as? NSView)?.window,
            !windowIDs.contains(ObjectIdentifier(owner))
          {
            return
          }
          if let other = object as? NSWindow, !windowIDs.contains(ObjectIdentifier(other)) {
            return
          }
          guard depth < 24, visited.count < 512 else {
            truncated = true
            return
          }
          guard visited.insert(ObjectIdentifier(object)).inserted else { return }
          let hidden =
            hiddenAncestor
            || ((object as? NSView)?.isHiddenOrHasHiddenAncestor ?? false)
            || ((object as? NSWindow).map { !$0.isVisible } ?? false)
          if hidden { hiddenCount += 1 }
          let element = object as? any NSAccessibilityProtocol
          let isElement = element?.isAccessibilityElement() ?? false
          let frame = element?.accessibilityFrame()
          let nonempty = frame.map { !$0.isEmpty } ?? false
          if element != nil { protocolCount += 1 }
          if isElement { elementCount += 1 }
          if isElement && nonempty { nonemptyCount += 1 }
          if isElement && nonempty && !hidden { acceptedCount += 1 }
          let id =
            element?.accessibilityIdentifier() ?? stringGetter(object, "accessibilityIdentifier")
            ?? "nil"
          let label =
            element?.accessibilityLabel() ?? stringGetter(object, "accessibilityLabel") ?? "nil"
          let role =
            element?.accessibilityRole()?.rawValue ?? stringGetter(object, "accessibilityRole")
            ?? "nil"
          let line =
            "type=\(short(String(reflecting: type(of: object)))) role=\(short(role)) id=\(short(id)) label=\(short(label)) frame=\(String(describing: frame)) protocol=\(element != nil) isElement=\(isElement) nonempty=\(nonempty) hiddenPath=\(hidden)"
          if samples.count < 24 { samples.append(line) }
          if id == identifier, matches.count < 8 { matches.append(line) }
          let axChildren = element?.accessibilityChildren() ?? childrenGetter(object)
          if axChildren.count > 64 { truncated = true }
          for child in axChildren.prefix(64) {
            visit(child as AnyObject, hiddenAncestor: hidden, depth: depth + 1)
          }
          if let view = object as? NSView {
            if view.subviews.count > 64 { truncated = true }
            for child in view.subviews.prefix(64) {
              visit(child, hiddenAncestor: hidden, depth: depth + 1)
            }
          }
          if let current = object as? NSWindow {
            if let content = current.contentView {
              visit(content, hiddenAncestor: hidden, depth: depth + 1)
            }
            for child in (current.sheets + (current.childWindows ?? [])).prefix(16) {
              visit(child, hiddenAncestor: hidden, depth: depth + 1)
            }
          }
        }
        visit(window, hiddenAncestor: false, depth: 0)
        print(
          "CATALOG_HOSTED_DIAGNOSTIC traversal raw=\(visited.count) protocol=\(protocolCount) isElement=\(elementCount) elementAndNonempty=\(nonemptyCount) hiddenPath=\(hiddenCount) accepted=\(acceptedCount) truncated=\(truncated)"
        )
        for sample in samples { print("CATALOG_HOSTED_DIAGNOSTIC node \(sample)") }
        print("CATALOG_HOSTED_DIAGNOSTIC matchingIdentifierCount=\(matches.count)")
        for match in matches { print("CATALOG_HOSTED_DIAGNOSTIC matchingIdentifier \(match)") }
      }

      func element(
        id: String? = nil, label: String? = nil, containing: String? = nil,
        role: NSAccessibility.Role? = nil
      ) async throws -> any NSAccessibilityProtocol {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
          try Task.checkCancellation()
          if let found = elements.first(where: {
            (id == nil || $0.accessibilityIdentifier() == id)
              && (label == nil || $0.accessibilityLabel() == label
                || $0.accessibilityTitle() == label)
              && (role == nil || $0.accessibilityRole() == role)
              && (containing == nil || text($0).contains(containing!))
          }) {
            return found
          }
          try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw WorkspaceError(
          message:
            "Hosted control unavailable: \(id ?? label ?? containing ?? "unknown"); actual XCUI remains pending",
          violations: [])
      }

      func text(_ element: any NSAccessibilityProtocol) -> String {
        [
          element.accessibilityLabel(), element.accessibilityTitle(),
          element.accessibilityValue() as? String,
        ].compactMap { $0 }.joined(separator: " ")
      }

      func press(
        id: String? = nil, label: String? = nil, containing: String? = nil,
        role: NSAccessibility.Role? = nil
      ) async throws {
        let control = try await element(id: id, label: label, containing: containing, role: role)
        try #require(control.isAccessibilityEnabled(), "Hosted control is disabled")
        try #require(control.accessibilityPerformPress(), "Rendered control refused AX press")
      }

      func choose(id: String, containing description: String) async throws {
        // Opening an in-process popup can enter a modal tracking loop. Inspect its
        // rendered menu and send the native control action, never a model mutation.
        let element = try await element(id: id)
        let popup = try #require(element as? NSPopUpButton, "Hosted picker is not an AppKit popup")
        try #require(popup.isEnabled)
        let menu = try #require(popup.menu)
        let index = try #require(menu.items.firstIndex { $0.title.contains(description) })
        try #require(menu.items[index].isEnabled)
        popup.selectItem(at: index)
        try #require(popup.sendAction(popup.action, to: popup.target))
      }

      func replace(id: String, with value: String) async throws {
        let field = try await element(id: id, role: .textField)
        try #require(field.isAccessibilityEnabled())
        field.setAccessibilityValue(value)
        _ = window.makeFirstResponder(nil)
        try await expectValue(id: id, value)
      }

      func expectValue(id: String, _ value: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
          try Task.checkCancellation()
          if elements.contains(where: {
            $0.accessibilityIdentifier() == id && $0.accessibilityValue() as? String == value
          }) {
            return
          }
          try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw WorkspaceError(message: "Rendered \(id) did not retain \(value)", violations: [])
      }

      func expectText(_ value: String) async throws {
        _ = try await element(containing: value)
      }

      func escape() throws {
        let event = try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(event)
      }
    }
  #endif

  // Explicitly run this preparation test before the allocated native UI case.
  // A Mac fixture is a NEW external file. A simulator fixture must name its exact UDID.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_DATABASE"] != nil
        || ProcessInfo.processInfo.environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] != nil))
  func prepareCatalogRecordUIFixture() async throws {
    let environment = ProcessInfo.processInfo.environment
    let runtime = try LifeCoreRuntime()
    let file: URL
    #if targetEnvironment(simulator)
      try #require(environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] == environment["SIMULATOR_UDID"])
      try #require(environment["LIFE_UI_TEST_CATALOG_SIMULATOR"] != nil)
      file = try WorkspaceModel.localURL()
    #elseif os(macOS)
      let path = try #require(environment["LIFE_UI_TEST_CATALOG_DATABASE"])
      file = URL(fileURLWithPath: path)
      try #require(file.lastPathComponent == "catalog-acceptance.sqlite")
      try #require(
        !FileManager.default.fileExists(atPath: file.path),
        "Refuse to overwrite an existing database")
    #else
      return
    #endif
    let existed = FileManager.default.fileExists(atPath: file.path)
    let workspace = try NativeWorkspace(path: file.path, runtime: runtime)
    if !existed { try await workspace.createSample() }
    // Never modify existing records/fixtures when a preparation is accidentally repeated.
    try #require(
      !(try await workspace.catalog().tables.contains { $0["id"] == .string("record_examples") }))
    try Self.seed(runtime)
    try await Self.establishCoverage(workspace, runtime: runtime)
    let writeability = try await workspace.writeability(table: "record_examples")
    try #require(
      writeability.writable, Comment(rawValue: writeability.reason?.message ?? "Not writable"))
    try await workspace.close()
  }

  // The real core must issue its coverage certificates through a complete sync.
  // Do not manufacture _core_coverage rows or bypass the invariant write gate.
  private static func establishCoverage(_ workspace: NativeWorkspace, runtime: LifeCoreRuntime)
    async throws
  {
    let snapshot = runtime.context.evaluateScript(
      #"""
      JSON.stringify({
        schema: LifeSql.all('SELECT applied_at,ddl FROM _schema_log ORDER BY id'),
        tables: Object.fromEntries(LifeSql.all("SELECT name FROM sqlite_master WHERE type='table'")
          .filter(r => !r.name.startsWith('_') && !r.name.startsWith('sqlite_'))
          .map(r => [r.name, LifeSql.all('SELECT * FROM "'+r.name.replaceAll('"','""')+'" ORDER BY id')]))
      })
      """#)
    try #require(runtime.context.exception == nil)
    let bytes = Data(try #require(snapshot?.toString()).utf8)
    let source = try JSONDecoder().decode(CatalogAcceptanceHub.Snapshot.self, from: bytes)
    CatalogAcceptanceHub.install(source)
    defer { CatalogAcceptanceHub.clear() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogAcceptanceHub.self]
    let hub = try HubTransport(
      endpoint: "https://catalog-acceptance.invalid", token: "fixture-scoped-token",
      configuration: configuration)
    let result = try await workspace.sync(using: hub)
    try #require(result.skipped.isEmpty && result.rejected.isEmpty)
  }

  private static func history(_ runtime: LifeCoreRuntime) throws -> String {
    let value = runtime.context.evaluateScript(
      "JSON.stringify(LifeSql.all(\"SELECT * FROM history WHERE tbl='record_examples' ORDER BY id\"))"
    )
    try #require(runtime.context.exception == nil)
    return try #require(value?.toString())
  }

  private static func seed(_ runtime: LifeCoreRuntime) throws {
    runtime.context.evaluateScript(
      #"""
      const ddl = `CREATE TABLE record_examples (
        id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT,
        title TEXT, detail TEXT, state TEXT, locked TEXT, computed TEXT)`;
      LifeSql.run(ddl);
      LifeSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
      LifeSql.run("INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('record_examples','table','title','Synthetic catalog acceptance')");
      for (const [col,label,type,sort,required,description,options,immutable,derived] of [
        ['title','Title','text',0,1,'Short fixture title.',null,0,null],
        ['detail','Detail','text',1,0,'A second independent edit.',null,0,null],
        ['state','State','select',2,0,'Choose a fixture state.',JSON.stringify([{v:'Draft',d:'Still being prepared.'},{v:'Ready',d:'Ready for review.'}]),0,null],
        ['locked','Locked','text',3,0,'Set once by the creator.',null,1,null],
        ['computed','Computed','text',4,0,'Filled by the fixture derivation.',null,0,'fixture-derivation']
      ]) LifeSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort,required,description,options,immutable,derived_by) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        ['record_examples.'+col,'record_examples',col,label,type,sort,required,description,options,immutable,derived]);
      LifeSql.run("INSERT INTO catalog_rules(id,tbl,kind,enforce,sql,text) VALUES (?,?,?,?,?,?)",
        ['catalog-title','record_examples','invariant',1,"SELECT id FROM changed WHERE title='Blocked'",'Fixture title is blocked.']);
      LifeSql.run("INSERT INTO record_examples VALUES ('catalog-record','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z',NULL,NULL,'Catalog fixture','Original detail','Draft','Immutable fixture value','Derived fixture value')");
      """#)
    try #require(
      runtime.context.exception == nil,
      Comment(rawValue: runtime.context.exception?.toString() ?? "Fixture SQL failed"))
  }
}

// Isolated, in-process transport of the synthetic snapshot, following HubSyncTests.
// Only the hub is a fixture: schema import, coverage, rule evaluation and writes use core.
private final class CatalogAcceptanceHub: URLProtocol, @unchecked Sendable {
  struct Snapshot: Decodable, Sendable {
    let schema: [WorkspaceRecord]
    let tables: [String: [WorkspaceRecord]]
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var source: Snapshot?
  static func install(_ snapshot: Snapshot) { lock.withLock { source = snapshot } }
  static func clear() { lock.withLock { source = nil } }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "catalog-acceptance.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    do {
      guard let source = Self.lock.withLock({ Self.source }),
        request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-scoped-token",
        request.httpMethod == "POST"
      else { throw URLError(.badServerResponse) }
      var bytes = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          bytes.append(contentsOf: buffer[..<count])
        }
      }
      let body = try JSONDecoder().decode(WorkspaceRecord.self, from: bytes)
      let data: JSONValue
      switch request.url?.path {
      case "/v1/schema/pull":
        data = .object(["entries": .array(source.schema.map(JSONValue.object))])
      case "/v1/stats":
        data = .object(["tables": .object(source.tables.mapValues { .number(Double($0.count)) })])
      case "/v1/cursor":
        data = .object([
          "max_hub_at": .string(""),
          "tables": .object(source.tables.mapValues { _ in .string("") }),
        ])
      case "/v1/rows/pull":
        let rows = source.tables[body["table"]?.text ?? ""] ?? []
        let limit = Int(body["limit"]?.text ?? "1000") ?? 1000
        let page = Array(
          rows.filter {
            body["after"] == nil || ($0["id"]?.text ?? "") > (body["after"]?.text ?? "")
          }.prefix(limit))
        data = .object([
          "rows": .array(page.map(JSONValue.object)),
          "next_cursor": page.count == limit ? (page.last?["id"] ?? .null) : .null,
        ])
      case "/v1/rows/push":
        guard case .array(let rows) = body["rows"] else { throw URLError(.badServerResponse) }
        data = .object(["upserted": .number(Double(rows.count)), "rejected": .array([])])
      default: throw URLError(.badURL)
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "Date": formatter.string(from: Date())])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONEncoder().encode(data))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
}
